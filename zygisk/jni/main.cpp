#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>
#include <sys/types.h>
#include <unistd.h>

#include "zygisk.hpp"

namespace {

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
    char mfr[PROP_VALUE_MAX];
};

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

    if (is_excluded_package(proc_name)) {
        write_exact(fd, &reply, sizeof(reply));
        return;
    }

    if (FILE *mf = fopen(kMfrPath, "r")) {
        if (fgets(reply.mfr, sizeof(reply.mfr), mf)) {
            trim_line(reply.mfr);
            if (reply.mfr[0] != '\0') {
                reply.should_spoof = 1;
            }
        }
        fclose(mf);
    }

    write_exact(fd, &reply, sizeof(reply));
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
        // Always dlclose after postAppSpecialize so neither our .so nor libzygisk.so
        // stays mapped in /proc/self/maps (no persistent native hooks installed).
        api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);

        if (!args || !args->nice_name) return;

        const char *raw_name = env_->GetStringUTFChars(args->nice_name, nullptr);
        if (!raw_name) return;

        char proc_name[256] = {0};
        strncpy(proc_name, raw_name, sizeof(proc_name) - 1);
        env_->ReleaseStringUTFChars(args->nice_name, raw_name);

        int fd = api_->connectCompanion();
        if (fd < 0) return;

        uint32_t len = static_cast<uint32_t>(strlen(proc_name));
        CompanionReply reply{};
        bool ok = write_exact(fd, &len, sizeof(len)) &&
                  write_exact(fd, proc_name, len) &&
                  read_exact(fd, &reply, sizeof(reply));
        close(fd);

        if (!ok || !reply.should_spoof || reply.mfr[0] == '\0') return;

        strncpy(mfr_, reply.mfr, sizeof(mfr_) - 1);
        mfr_[sizeof(mfr_) - 1] = '\0';
        should_spoof_ = true;
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (!should_spoof_) return;

        jclass build_cls = env_->FindClass("android/os/Build");
        if (env_->ExceptionCheck() || !build_cls) {
            env_->ExceptionClear();
            return;
        }

        set_build_field(env_, build_cls, "MANUFACTURER", mfr_);
        set_build_field(env_, build_cls, "MANUFACTURER_FOR_ATTESTATION", mfr_);
        env_->DeleteLocalRef(build_cls);
    }

private:
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool should_spoof_ = false;
    char mfr_[PROP_VALUE_MAX] = {0};
};

} // namespace

REGISTER_ZYGISK_MODULE(RkpMfrModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
