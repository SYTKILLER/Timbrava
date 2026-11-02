// NAPI 桥:命令进 + 事件轮询出(Flick 式极简 FFI 契约)。
// 导出:openFd / play / pause / stop / seek / setVolume / getPosition / getDuration /
//       getTrackInfo / pollEvents / shutdown
#include "napi/native_api.h"

#include <string>
#include <vector>
#include <sys/stat.h>
#include <fcntl.h>

#include "include/engine.h"

#define LOG_TAG "[TimbravaNative][Napi]"
#include <hilog/log.h>

static napi_value JOpenFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int fd = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &fd);
    }
    napi_value result = nullptr;
    napi_create_object(env, &result);
    std::string errMsg;
    timbrava::TrackInfo trackInfo;
    bool ok = timbrava::Engine::instance().openTrack(fd, &errMsg, &trackInfo);
    napi_value v;
    napi_get_boolean(env, ok, &v);
    napi_set_named_property(env, result, "ok", v);
    if (ok) {
        napi_create_int32(env, trackInfo.sampleRate, &v);
        napi_set_named_property(env, result, "sampleRate", v);
        napi_create_int32(env, trackInfo.channels, &v);
        napi_set_named_property(env, result, "channels", v);
        napi_create_int32(env, trackInfo.bitsPerSample, &v);
        napi_set_named_property(env, result, "bitDepth", v);
        napi_create_int64(env, trackInfo.totalFrames, &v);
        napi_set_named_property(env, result, "totalFrames", v);
        napi_create_string_utf8(env, trackInfo.codec, NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, "codec", v);
    } else {
        napi_create_string_utf8(env, errMsg.c_str(), NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, "msg", v);
    }
    return result;
}

static napi_value JVoidCmd(napi_env env, napi_callback_info info, void (timbrava::Engine::*cmd)())
{
    (void)env;
    (void)info;
    (timbrava::Engine::instance().*cmd)();
    return nullptr;
}

static napi_value JPlay(napi_env env, napi_callback_info info)
{
    return JVoidCmd(env, info, &timbrava::Engine::play);
}

static napi_value JPause(napi_env env, napi_callback_info info)
{
    return JVoidCmd(env, info, &timbrava::Engine::pause);
}

static napi_value JStop(napi_env env, napi_callback_info info)
{
    return JVoidCmd(env, info, &timbrava::Engine::stopTrack);
}

static napi_value JSeek(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double ms = 0;
    if (argc >= 1) {
        napi_get_value_double(env, args[0], &ms);
    }
    std::string errMsg;
    bool ok = timbrava::Engine::instance().seekMs(static_cast<int64_t>(ms), &errMsg);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    if (!ok) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "seek rejected: %{public}s", errMsg.c_str());
    }
    return result;
}

static napi_value JSetVolume(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double vol = 1.0;
    if (argc >= 1) {
        napi_get_value_double(env, args[0], &vol);
    }
    timbrava::Engine::instance().setVolume(static_cast<float>(vol));
    return nullptr;
}

static napi_value JGetPosition(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result;
    napi_create_double(env, static_cast<double>(timbrava::Engine::instance().positionMs()), &result);
    return result;
}

static napi_value JGetDuration(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result;
    napi_create_double(env, static_cast<double>(timbrava::Engine::instance().durationMs()), &result);
    return result;
}

static napi_value JGetTrackInfo(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v;
    napi_get_boolean(env, timbrava::Engine::instance().hasTrack(), &v);
    napi_set_named_property(env, result, "hasTrack", v);
    napi_create_double(env, static_cast<double>(timbrava::Engine::instance().positionMs()), &v);
    napi_set_named_property(env, result, "positionMs", v);
    napi_create_double(env, static_cast<double>(timbrava::Engine::instance().durationMs()), &v);
    napi_set_named_property(env, result, "durationMs", v);
    return result;
}

static napi_value JPollEvents(napi_env env, napi_callback_info info)
{
    (void)info;
    std::vector<std::string> events;
    timbrava::Engine::instance().pollEvents(events);
    napi_value arr;
    napi_create_array_with_length(env, events.size(), &arr);
    for (size_t i = 0; i < events.size(); i++) {
        napi_value s;
        napi_create_string_utf8(env, events[i].c_str(), NAPI_AUTO_LENGTH, &s);
        napi_set_element(env, arr, static_cast<uint32_t>(i), s);
    }
    return arr;
}

static napi_value JShutdown(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    timbrava::Engine::instance().shutdown();
    return nullptr;
}


// 调试/验证通道:应用对自己沙箱目录授权(宿主 shell uid 需穿越写入语料)
static napi_value JChmodPath(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char path[512] = {0};
    size_t len = 0;
    int mode = 0;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, args[0], path, sizeof(path), &len);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &mode);
    }
    int rc = ::chmod(path, static_cast<mode_t>(mode));
    if (rc != 0) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "chmod %{public}s -> %{public}d fail errno=%{public}d", path, mode, errno);
    }
    napi_value result;
    napi_get_boolean(env, rc == 0, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"openFd", nullptr, JOpenFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"play", nullptr, JPlay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pause", nullptr, JPause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, JStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seek", nullptr, JSeek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVolume", nullptr, JSetVolume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPosition", nullptr, JGetPosition, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDuration", nullptr, JGetDuration, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getTrackInfo", nullptr, JGetTrackInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pollEvents", nullptr, JPollEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shutdown", nullptr, JShutdown, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"chmodPath", nullptr, JChmodPath, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module timbravaModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "timbrava_core",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTimbravaModule(void)
{
    napi_module_register(&timbravaModule);
}
