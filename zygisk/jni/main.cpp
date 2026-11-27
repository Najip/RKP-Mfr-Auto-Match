#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysmacros.h>
#include <sys/system_properties.h>
#include <sys/types.h>
#include <unistd.h>

#include "zygisk.hpp"

namespace {

constexpr const char *kConfPath = "/data/adb/rkp_mfr_auto.conf";
constexpr const char *kMfrPath = "/data/adb/rkp_mfr_auto.mfr";
constexpr const char *kExcludePath = "/data/adb/rkp_mfr_auto.exclude";

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
    uint8_t should_spoof;
    uint8_t spoof_vendor;
    char mfr[PROP_VALUE_MAX];
};

static char g_mfr[PROP_VALUE_MAX] = {0};
static bool g_spoof_vendor = false;

using PropCallback = void (*)(void *, const char *, const char *, uint32_t);
static void (*orig_read_callback)(const prop_info *, PropCallback, void *) = nullptr;
static int (*orig_prop_get)(const char *, char *) = nullptr;

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
    // Also match cloned GoogleCamera packages (e.g. com.google.android.GoogleCameraEng)
    if (strcmp(pattern, "com.google.android.GoogleCamera") == 0) return true;
    return false;
}

static bool is_excluded_package(const char *proc_name) {
    if (!proc_name || proc_name[0] == '\0') return true;

    for (const char *pat : kDefaultExcluded) {
        if (pkg_matches(proc_name, pat)) return true;
    }

    FILE *fp = fopen(kExcludePath, "r");
    if (fp) {
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
    }
    return false;
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

    // Default to zygisk when running inside Zygisk unless explicitly set to resetprop
    bool use_zygisk = true;
    bool spoof_vendor = false;

    if (FILE *cf = fopen(kConfPath, "r")) {
        char line[256];
        while (fgets(line, sizeof(line), cf)) {
            trim_line(line);
            if (strncmp(line, "SPOOF_MODE=", 11) == 0) {
                const char *v = line + 11;
                if (strcmp(v, "resetprop") == 0) {
                    use_zygisk = false;
                } else if (strcmp(v, "zygisk") == 0) {
                    use_zygisk = true;
                }
            } else if (strncmp(line, "SPOOF_VENDOR_MFR=", 17) == 0) {
                spoof_vendor = (line[17] == '1');
            }
        }
        fclose(cf);
    }

    if (!use_zygisk || is_excluded_package(proc_name)) {
        write_exact(fd, &reply, sizeof(reply));
        return;
    }

    if (FILE *mf = fopen(kMfrPath, "r")) {
        if (fgets(reply.mfr, sizeof(reply.mfr), mf)) {
            trim_line(reply.mfr);
            if (reply.mfr[0] != '\0') {
                reply.should_spoof = 1;
                reply.spoof_vendor = spoof_vendor ? 1 : 0;
            }
        }
        fclose(mf);
    }

    write_exact(fd, &reply, sizeof(reply));
}

static bool should_spoof_prop(const char *name) {
    if (strcmp(name, "ro.product.manufacturer") == 0) return true;
    if (strcmp(name, "ro.product.manufacturer_for_attestation") == 0) return true;
    if (g_spoof_vendor && strcmp(name, "ro.product.vendor.manufacturer") == 0) return true;
    return false;
}

struct ReadCookie {
    PropCallback orig_cb;
    void *orig_cookie;
};

static void read_cb_trampoline(void *cookie, const char *name, const char *value, uint32_t serial) {
    auto *rc = static_cast<ReadCookie *>(cookie);
    if (name && should_spoof_prop(name)) {
        rc->orig_cb(rc->orig_cookie, name, g_mfr, serial);
    } else {
        rc->orig_cb(rc->orig_cookie, name, value, serial);
    }
}

static void hooked_read_callback(const prop_info *pi, PropCallback cb, void *cookie) {
    if (!orig_read_callback) return;
    if (!cb) {
        orig_read_callback(pi, cb, cookie);
        return;
    }
    ReadCookie rc{cb, cookie};
    orig_read_callback(pi, read_cb_trampoline, &rc);
}

static int hooked_prop_get(const char *name, char *value) {
    if (name && value && should_spoof_prop(name)) {
        size_t len = strlen(g_mfr);
        if (len >= PROP_VALUE_MAX) len = PROP_VALUE_MAX - 1;
        memcpy(value, g_mfr, len);
        value[len] = '\0';
        return static_cast<int>(len);
    }
    return orig_prop_get ? orig_prop_get(name, value) : 0;
}

static bool find_lib_dev_inode(const char *suffix, dev_t *out_dev, ino_t *out_ino) {
    FILE *fp = fopen("/proc/self/maps", "r");
    if (!fp) return false;
    char line[512];
    size_t slen = strlen(suffix);
    while (fgets(line, sizeof(line), fp)) {
        unsigned int maj = 0, min = 0;
        unsigned long ino = 0;
        char path[256] = {0};
        if (sscanf(line, "%*lx-%*lx %*4s %*lx %x:%x %lu %255s", &maj, &min, &ino, path) == 4) {
            size_t plen = strlen(path);
            if (plen >= slen && strcmp(path + plen - slen, suffix) == 0 && ino != 0) {
                *out_dev = makedev(maj, min);
                *out_ino = static_cast<ino_t>(ino);
                fclose(fp);
                return true;
            }
        }
    }
    fclose(fp);
    return false;
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

        if (!ok || !reply.should_spoof || reply.mfr[0] == '\0') {
            api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        strncpy(g_mfr, reply.mfr, sizeof(g_mfr) - 1);
        g_mfr[sizeof(g_mfr) - 1] = '\0';
        g_spoof_vendor = (reply.spoof_vendor != 0);
        should_spoof_ = true;

        dev_t dev = 0;
        ino_t ino = 0;
        if (find_lib_dev_inode("/libandroid_runtime.so", &dev, &ino)) {
            api_->pltHookRegister(dev, ino, "__system_property_read_callback",
                                  reinterpret_cast<void *>(hooked_read_callback),
                                  reinterpret_cast<void **>(&orig_read_callback));
            api_->pltHookRegister(dev, ino, "__system_property_get",
                                  reinterpret_cast<void *>(hooked_prop_get),
                                  reinterpret_cast<void **>(&orig_prop_get));
            api_->pltHookCommit();
        }
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (!should_spoof_) return;

        jclass build_cls = env_->FindClass("android/os/Build");
        if (env_->ExceptionCheck() || !build_cls) {
            env_->ExceptionClear();
            return;
        }

        set_build_field(env_, build_cls, "MANUFACTURER", g_mfr);
        set_build_field(env_, build_cls, "MANUFACTURER_FOR_ATTESTATION", g_mfr);
        env_->DeleteLocalRef(build_cls);
    }

private:
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool should_spoof_ = false;
};

} // namespace

REGISTER_ZYGISK_MODULE(RkpMfrModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
