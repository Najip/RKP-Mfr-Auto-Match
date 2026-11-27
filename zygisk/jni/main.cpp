#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/system_properties.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "zygisk.hpp"

namespace {

constexpr const char *kRealMfrPath = "/data/adb/rkp_mfr_auto.real_mfr";
constexpr const char *kConfPath = "/data/adb/rkp_mfr_auto.conf";
constexpr const char *kExcludePath = "/data/adb/rkp_mfr_auto.exclude";
constexpr const char *kCamAutoPath = "/data/adb/rkp_mfr_auto.cam_auto";
constexpr const char *kDebugLogPath = "/data/adb/rkp_mfr_auto.log";
constexpr off_t kMaxLogBytes = 256 * 1024;

constexpr const char *kDefaultExcluded[] = {
    "com.google.android.GoogleCamera",
    "com.google.android.apps.camera.services",
    "com.android.camera",
    "com.sec.android.app.camera",
    "com.oplus.camera",
    "com.oneplus.camera",
    "org.codeaurora.snapcam",
    "com.xiaomi.camera",
};

struct CompanionReply {
    uint8_t should_restore;
    uint8_t restore_vendor;
    char real_mfr[PROP_VALUE_MAX];
};

static char g_real_mfr[PROP_VALUE_MAX] = {0};
static bool g_restore_vendor = false;

using prop_callback_t = void (*)(void *, const char *, const char *, uint32_t);
using prop_read_cb_t = void (*)(const prop_info *, prop_callback_t, void *);
using prop_get_t = int (*)(const char *, char *);

static prop_read_cb_t orig_read_callback = nullptr;
static prop_get_t orig_prop_get = nullptr;

static bool is_target_prop(const char *name) {
    if (!name) return false;
    if (strcmp(name, "ro.product.manufacturer") == 0) return true;
    if (strcmp(name, "ro.product.manufacturer_for_attestation") == 0) return true;
    if (g_restore_vendor && strcmp(name, "ro.product.vendor.manufacturer") == 0) return true;
    return false;
}

struct CallbackWrap {
    prop_callback_t orig_cb;
    void *orig_cookie;
};

static void wrapped_prop_callback(void *cookie, const char *name, const char *value, uint32_t serial) {
    auto *w = static_cast<CallbackWrap *>(cookie);
    if (g_real_mfr[0] != '\0' && is_target_prop(name)) {
        w->orig_cb(w->orig_cookie, name, g_real_mfr, serial);
    } else {
        w->orig_cb(w->orig_cookie, name, value, serial);
    }
}

static void hooked_read_callback(const prop_info *pi, prop_callback_t callback, void *cookie) {
    if (!orig_read_callback) return;
    if (g_real_mfr[0] != '\0' && callback) {
        CallbackWrap w{callback, cookie};
        orig_read_callback(pi, wrapped_prop_callback, &w);
        return;
    }
    orig_read_callback(pi, callback, cookie);
}

static int hooked_prop_get(const char *name, char *value) {
    if (g_real_mfr[0] != '\0' && value && is_target_prop(name)) {
        size_t len = strlen(g_real_mfr);
        if (len >= PROP_VALUE_MAX) len = PROP_VALUE_MAX - 1;
        memcpy(value, g_real_mfr, len);
        value[len] = '\0';
        return static_cast<int>(len);
    }
    return orig_prop_get ? orig_prop_get(name, value) : 0;
}

static bool read_exact(int fd, void *buf, size_t len) {
    auto *p = static_cast<uint8_t *>(buf);
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) return false;
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

static bool write_exact(int fd, const void *buf, size_t len) {
    const auto *p = static_cast<const uint8_t *>(buf);
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) return false;
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

static void trim_line(char *s) {
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ' || s[len - 1] == '\t')) {
        s[--len] = '\0';
    }
}

static bool pkg_matches(const char *proc_name, const char *pattern) {
    size_t plen = strlen(pattern);
    if (plen == 0) return false;
    if (strncmp(proc_name, pattern, plen) != 0) return false;
    char next = proc_name[plen];
    if (next == '\0' || next == ':') return true;
    // Match cloned GoogleCamera packages (e.g. com.google.android.GoogleCameraEng)
    if (strcmp(pattern, "com.google.android.GoogleCamera") == 0) return true;
    return false;
}

static bool file_has_package(const char *path, const char *proc_name) {
    FILE *fp = fopen(path, "r");
    if (!fp) return false;
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        trim_line(line);
        if (line[0] == '\0' || line[0] == '#') continue;
        if (pkg_matches(proc_name, line)) {
            fclose(fp);
            return true;
        }
    }
    fclose(fp);
    return false;
}

static bool is_whitelisted_package(const char *proc_name) {
    if (!proc_name || proc_name[0] == '\0') return false;

    for (const char *pat : kDefaultExcluded) {
        if (pkg_matches(proc_name, pat)) return true;
    }

    if (file_has_package(kCamAutoPath, proc_name)) return true;
    if (file_has_package(kExcludePath, proc_name)) return true;
    return false;
}

static void append_debug_log(const char *proc_name, const CompanionReply &reply, bool whitelisted) {
    struct stat st{};
    const char *mode = "a";
    if (stat(kDebugLogPath, &st) == 0 && st.st_size > kMaxLogBytes) {
        mode = "w";
    }
    FILE *lf = fopen(kDebugLogPath, mode);
    if (!lf) return;
    time_t now = time(nullptr);
    struct tm tm_buf{};
    localtime_r(&now, &tm_buf);
    char ts[32] = {0};
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_buf);
    if (reply.should_restore) {
        fprintf(lf, "[%s] [zygisk] %s -> RESTORE real_mfr=%s vendor=%u\n",
                ts, proc_name, reply.real_mfr, static_cast<unsigned>(reply.restore_vendor));
    } else if (whitelisted) {
        fprintf(lf, "[%s] [zygisk] %s -> WHITELISTED_NO_REAL_MFR (dlclose)\n", ts, proc_name);
    } else {
        fprintf(lf, "[%s] [zygisk] %s -> DLCLOSE\n", ts, proc_name);
    }
    fclose(lf);
    chmod(kDebugLogPath, 0644);
}

static void companion_handler(int fd) {
    CompanionReply reply{};
    uint32_t name_len = 0;
    if (!read_exact(fd, &name_len, sizeof(name_len)) || name_len == 0 || name_len >= 256) {
        write_exact(fd, &reply, sizeof(reply));
        return;
    }

    char proc_name[256] = {0};
    if (!read_exact(fd, proc_name, name_len)) {
        return;
    }
    proc_name[name_len] = '\0';

    bool spoof_vendor = false;
    bool debug_log = false;
    if (FILE *cf = fopen(kConfPath, "r")) {
        char line[128];
        while (fgets(line, sizeof(line), cf)) {
            trim_line(line);
            if (strcmp(line, "SPOOF_VENDOR_MFR=1") == 0) spoof_vendor = true;
            else if (strcmp(line, "DEBUG_LOG=1") == 0) debug_log = true;
        }
        fclose(cf);
    }

    bool whitelisted = is_whitelisted_package(proc_name);

    // Only activate for whitelisted / fixed camera apps so normal apps (including detectors)
    // immediately dlclose this library and leave zero Zygisk maps behind.
    if (whitelisted) {
        if (FILE *mf = fopen(kRealMfrPath, "r")) {
            if (fgets(reply.real_mfr, sizeof(reply.real_mfr), mf)) {
                trim_line(reply.real_mfr);
                if (reply.real_mfr[0] != '\0') {
                    reply.should_restore = 1;
                    reply.restore_vendor = spoof_vendor ? 1 : 0;
                }
            }
            fclose(mf);
        }
    }

    if (debug_log) {
        append_debug_log(proc_name, reply, whitelisted);
    }

    write_exact(fd, &reply, sizeof(reply));
}

static bool find_lib_dev_inode(const char *lib_suffix, dev_t *out_dev, ino_t *out_ino) {
    FILE *fp = fopen("/proc/self/maps", "r");
    if (!fp) return false;
    char line[512];
    bool found = false;
    while (fgets(line, sizeof(line), fp)) {
        unsigned int maj = 0, min = 0;
        unsigned long long ino = 0;
        char path[256] = {0};
        if (sscanf(line, "%*x-%*x %*4s %*x %x:%x %llu %255s", &maj, &min, &ino, path) == 4) {
            size_t plen = strlen(path);
            size_t slen = strlen(lib_suffix);
            if (plen >= slen && strcmp(path + plen - slen, lib_suffix) == 0) {
                *out_dev = makedev(maj, min);
                *out_ino = static_cast<ino_t>(ino);
                found = true;
                break;
            }
        }
    }
    fclose(fp);
    return found;
}

static void set_build_field(JNIEnv *env, jclass build_cls, const char *field_name, const char *val) {
    jfieldID fid = env->GetStaticFieldID(build_cls, field_name, "Ljava/lang/String;");
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return;
    }
    if (!fid) return;
    jstring jval = env->NewStringUTF(val);
    if (!jval) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return;
    }
    env->SetStaticObjectField(build_cls, fid, jval);
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(jval);
}

class RkpMfrModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override {
        api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        if (!args || !args->nice_name) {
            api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        const char *raw_name = env_->GetStringUTFChars(args->nice_name, nullptr);
        if (!raw_name) {
            api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        char proc_name[256] = {0};
        strncpy(proc_name, raw_name, sizeof(proc_name) - 1);
        env_->ReleaseStringUTFChars(args->nice_name, raw_name);

        int fd = api_->connectCompanion();
        if (fd < 0) {
            api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        uint32_t len = static_cast<uint32_t>(strlen(proc_name));
        CompanionReply reply{};
        bool ok = write_exact(fd, &len, sizeof(len)) &&
                  write_exact(fd, proc_name, len) &&
                  read_exact(fd, &reply, sizeof(reply));
        close(fd);

        if (!ok || !reply.should_restore || reply.real_mfr[0] == '\0') {
            // Normal apps (including detectors): unload immediately so neither this .so
            // nor libzygisk.so stays in /proc/self/maps.
            api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        // Whitelisted / fixed camera app: restore stock manufacturer via PLT hooks + Build fields
        strncpy(g_real_mfr, reply.real_mfr, sizeof(g_real_mfr) - 1);
        g_real_mfr[sizeof(g_real_mfr) - 1] = '\0';
        g_restore_vendor = (reply.restore_vendor != 0);
        should_restore_ = true;

        dev_t dev = 0;
        ino_t ino = 0;
        if (find_lib_dev_inode("/libandroid_runtime.so", &dev, &ino)) {
            api_->pltHookRegister(
                dev, ino,
                "__system_property_read_callback",
                reinterpret_cast<void *>(hooked_read_callback),
                reinterpret_cast<void **>(&orig_read_callback));
            api_->pltHookRegister(
                dev, ino,
                "__system_property_get",
                reinterpret_cast<void *>(hooked_prop_get),
                reinterpret_cast<void **>(&orig_prop_get));
            api_->pltHookCommit();
        }
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (!should_restore_ || g_real_mfr[0] == '\0') return;

        jclass build_cls = env_->FindClass("android/os/Build");
        if (env_->ExceptionCheck() || !build_cls) {
            env_->ExceptionClear();
            return;
        }

        set_build_field(env_, build_cls, "MANUFACTURER", g_real_mfr);
        set_build_field(env_, build_cls, "MANUFACTURER_FOR_ATTESTATION", g_real_mfr);
        env_->DeleteLocalRef(build_cls);
    }

private:
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool should_restore_ = false;
};

} // namespace

REGISTER_ZYGISK_MODULE(RkpMfrModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
