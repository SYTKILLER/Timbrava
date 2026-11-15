// NAPI 桥:命令进 + 事件轮询出(Flick 式极简 FFI 契约)。
// 导出:openFd / play / pause / stop / seek / setVolume / getPosition / getDuration /
//       getTrackInfo / pollEvents / shutdown
#include "napi/native_api.h"

#include <string>
#include <vector>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include <CryptoArchitectureKit/crypto_common.h>
#include <CryptoArchitectureKit/crypto_digest.h>

#include "third_party/xxhash.h"

#include "include/engine.h"
#include "include/flac_tag_writer.h"
#include "include/viz.h"

#include <cstring>

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
        napi_create_int32(env, trackInfo.dsdRate, &v);
        napi_set_named_property(env, result, "dsdRate", v);
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

// gapless 预排(M3):下一曲 fd,格式一致才接受(fd 由 ArkTS 打开,native dup 后即可关)
static napi_value JOpenNextFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int fd = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &fd);
    }
    napi_value result;
    napi_get_boolean(env, timbrava::Engine::instance().openNextTrack(fd), &result);
    return result;
}

static napi_value JClearNextTrack(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    timbrava::Engine::instance().clearNextTrack();
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

static napi_value JSetPeqEnabled(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool on = false;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &on);
    }
    timbrava::Engine::instance().setPeqEnabled(on);
    return nullptr;
}

static napi_value JSetPeqBand(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int index = 0;
    int type = 0;
    double freq = 1000.0;
    double gain = 0.0;
    double q = 1.0;
    if (argc >= 5) {
        napi_get_value_int32(env, args[0], &index);
        napi_get_value_int32(env, args[1], &type);
        napi_get_value_double(env, args[2], &freq);
        napi_get_value_double(env, args[3], &gain);
        napi_get_value_double(env, args[4], &q);
    }
    timbrava::Engine::instance().setPeqBand(index, type, static_cast<float>(freq),
                                            static_cast<float>(gain), static_cast<float>(q));
    return nullptr;
}

static napi_value JSetReplayGain(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double tGain = 0;
    double tPeak = 1;
    double aGain = 0;
    double aPeak = 1;
    int mode = 0;
    if (argc >= 5) {
        napi_get_value_double(env, args[0], &tGain);
        napi_get_value_double(env, args[1], &tPeak);
        napi_get_value_double(env, args[2], &aGain);
        napi_get_value_double(env, args[3], &aPeak);
        napi_get_value_int32(env, args[4], &mode);
    }
    timbrava::Engine::instance().setReplayGain(static_cast<float>(tGain), static_cast<float>(tPeak),
                                               static_cast<float>(aGain), static_cast<float>(aPeak), mode);
    return nullptr;
}

static napi_value JShutdown(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    timbrava::Engine::instance().shutdown();
    return nullptr;
}

// ---------------- ReplayGain 扫描(napi 异步工作,Promise 返回) ----------------

struct AnalyzeCarrier {
    int fd = -1;
    bool ok = false;
    std::string errMsg;
    float rmsDb = 0.0f;
    float peak = 0.0f;
    int64_t durationMs = 0;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteAnalyze(napi_env env, void *data)
{
    AnalyzeCarrier *c = static_cast<AnalyzeCarrier *>(data);
    c->ok = timbrava::Engine::instance().analyzeTrack(c->fd, &c->rmsDb, &c->peak, &c->durationMs, &c->errMsg);
}

static void CompleteAnalyze(napi_env env, napi_status status, void *data)
{
    AnalyzeCarrier *c = static_cast<AnalyzeCarrier *>(data);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v;
    napi_get_boolean(env, c->ok, &v);
    napi_set_named_property(env, result, "ok", v);
    if (c->ok) {
        napi_create_double(env, static_cast<double>(c->rmsDb), &v);
        napi_set_named_property(env, result, "rmsDb", v);
        napi_create_double(env, static_cast<double>(c->peak), &v);
        napi_set_named_property(env, result, "peak", v);
        napi_create_double(env, static_cast<double>(c->durationMs), &v);
        napi_set_named_property(env, result, "durationMs", v);
    } else {
        napi_create_string_utf8(env, c->errMsg.c_str(), NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, "msg", v);
    }
    napi_resolve_deferred(env, c->deferred, result);
    napi_delete_async_work(env, c->work);
    delete c;
}

static napi_value JSetSpeed(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double speed = 1.0;
    if (argc >= 1) {
        napi_get_value_double(env, args[0], &speed);
    }
    timbrava::Engine::instance().setSpeed(static_cast<float>(speed));
    return nullptr;
}

static napi_value JSetSkipSilence(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool on = false;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &on);
    }
    timbrava::Engine::instance().setSkipSilence(on);
    return nullptr;
}

// 声道平衡 + 单声道(0.18.0):balance ∈ [-1,1],mono 合并左右
static napi_value JSetBalance(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double balance = 0.0;
    bool mono = false;
    if (argc >= 1) {
        napi_get_value_double(env, args[0], &balance);
    }
    if (argc >= 2) {
        napi_get_value_bool(env, args[1], &mono);
    }
    timbrava::Engine::instance().setBalance(static_cast<float>(balance), mono);
    return nullptr;
}

// crossfade(0.23.0):on+ms 启用两曲重叠渐变;ms<=0 关闭
static napi_value JSetCrossfade(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool on = false;
    double ms = 0;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &on);
    }
    if (argc >= 2) {
        napi_get_value_double(env, args[1], &ms);
    }
    timbrava::Engine::instance().setCrossfade(on, static_cast<int>(ms));
    return nullptr;
}

// 频谱可视化开关(0.18.0):仅无损引擎播放页启用,关闭时音频路径零开销
static napi_value JVizSetEnabled(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool on = false;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &on);
    }
    timbrava::Engine::instance().setVizEnabled(on);
    return nullptr;
}

// 频谱轮询:返回 {ok, frameId, rmsDb, peak, bands:Float32Array(48)}
static napi_value JVizPoll(napi_env env, napi_callback_info info)
{
    (void)info;
    timbrava::VizSnapshot snap;
    const bool has = timbrava::vizPoll(&snap);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v;
    napi_get_boolean(env, has, &v);
    napi_set_named_property(env, result, "ok", v);
    if (has) {
        napi_create_int32(env, snap.frameId, &v);
        napi_set_named_property(env, result, "frameId", v);
        napi_create_double(env, static_cast<double>(snap.rmsDb), &v);
        napi_set_named_property(env, result, "rmsDb", v);
        napi_create_double(env, static_cast<double>(snap.peak), &v);
        napi_set_named_property(env, result, "peak", v);
        void *data = nullptr;
        napi_value ab = nullptr;
        if (napi_create_arraybuffer(env, timbrava::kVizBandCount * sizeof(float), &data, &ab) == napi_ok &&
            data != nullptr && ab != nullptr) {
            memcpy(data, snap.bands, timbrava::kVizBandCount * sizeof(float));
            napi_value ta = nullptr;
            if (napi_create_typedarray(env, napi_float32_array, timbrava::kVizBandCount, ab, 0, &ta) == napi_ok &&
                ta != nullptr) {
                napi_set_named_property(env, result, "bands", ta);
            }
        }
    }
    return result;
}

static napi_value JAnalyzeFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    AnalyzeCarrier *c = new AnalyzeCarrier();
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &c->fd);
    }
    napi_value promise;
    napi_create_promise(env, &c->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "timbravaAnalyze", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteAnalyze, CompleteAnalyze, c, &c->work);
    napi_queue_async_work(env, c->work);
    return promise;
}

// ---------------- 波形包络(napi 异步工作,Promise 返回 Float32Array) ----------------
// fd 契约与 analyzeFd 一致:调用方保持 fd 打开至 Promise 完成。

struct EnvelopeCarrier {
    int fd = -1;
    int buckets = 400;
    bool ok = false;
    std::string errMsg;
    std::vector<float> data;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteEnvelope(napi_env env, void *data)
{
    EnvelopeCarrier *c = static_cast<EnvelopeCarrier *>(data);
    c->ok = timbrava::Engine::instance().analyzeEnvelope(c->fd, c->buckets, c->data, &c->errMsg);
}

static void CompleteEnvelope(napi_env env, napi_status status, void *data)
{
    EnvelopeCarrier *c = static_cast<EnvelopeCarrier *>(data);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v;
    napi_get_boolean(env, c->ok, &v);
    napi_set_named_property(env, result, "ok", v);
    if (c->ok && !c->data.empty()) {
        const size_t n = c->data.size();
        void *abData = nullptr;
        napi_value ab = nullptr;
        if (napi_create_arraybuffer(env, n * sizeof(float), &abData, &ab) == napi_ok &&
            abData != nullptr && ab != nullptr) {
            memcpy(abData, c->data.data(), n * sizeof(float));
            napi_value ta = nullptr;
            if (napi_create_typedarray(env, napi_float32_array, static_cast<size_t>(n), ab, 0, &ta) == napi_ok &&
                ta != nullptr) {
                napi_set_named_property(env, result, "data", ta);
            }
        }
    } else if (!c->ok) {
        napi_create_string_utf8(env, c->errMsg.c_str(), NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, "msg", v);
    }
    napi_resolve_deferred(env, c->deferred, result);
    napi_delete_async_work(env, c->work);
    delete c;
}

static napi_value JEnvelopeFd(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    EnvelopeCarrier *c = new EnvelopeCarrier();
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &c->fd);
    }
    if (argc >= 2) {
        double b = 400;
        napi_get_value_double(env, args[1], &b);
        c->buckets = static_cast<int>(b);
    }
    napi_value promise;
    napi_create_promise(env, &c->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "timbravaEnvelope", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteEnvelope, CompleteEnvelope, c, &c->work);
    napi_queue_async_work(env, c->work);
    return promise;
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

// ---------------- FLAC 标签写回(napi 异步工作,Promise 返回) ----------------

struct TagCarrier {
    std::string srcPath;
    std::string tmpPath;
    timbrava::FlacTags tags;
    bool ok = false;
    std::string errMsg;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteTags(napi_env env, void *data)
{
    TagCarrier *c = static_cast<TagCarrier *>(data);
    c->ok = timbrava::writeFlacTags(c->srcPath, c->tmpPath, c->tags, &c->errMsg);
}

static void CompleteTags(napi_env env, napi_status status, void *data)
{
    TagCarrier *c = static_cast<TagCarrier *>(data);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v;
    napi_get_boolean(env, c->ok, &v);
    napi_set_named_property(env, result, "ok", v);
    if (!c->ok) {
        napi_create_string_utf8(env, c->errMsg.c_str(), NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, "msg", v);
    }
    napi_resolve_deferred(env, c->deferred, result);
    napi_delete_async_work(env, c->work);
    delete c;
}

static std::string JsString(napi_env env, napi_value val)
{
    char buf[1024];
    size_t len = 0;
    if (napi_get_value_string_utf8(env, val, buf, sizeof(buf), &len) != napi_ok) {
        return "";
    }
    return std::string(buf, len);
}

static napi_value JWriteFlacTags(napi_env env, napi_callback_info info)
{
    // 参数:srcPath, tmpPath, title, artist, album, albumArtist, genre, year, trackNo, discNo
    size_t argc = 10;
    napi_value args[10] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    TagCarrier *c = new TagCarrier();
    auto pickAt = [&](size_t idx) -> std::string {
        return idx < argc && args[idx] != nullptr ? JsString(env, args[idx]) : "";
    };
    c->srcPath = pickAt(0);
    c->tmpPath = pickAt(1);
    c->tags.title = pickAt(2);
    c->tags.artist = pickAt(3);
    c->tags.album = pickAt(4);
    c->tags.albumArtist = pickAt(5);
    c->tags.genre = pickAt(6);
    c->tags.year = pickAt(7);
    c->tags.trackNo = pickAt(8);
    c->tags.discNo = pickAt(9);
    napi_value promise;
    napi_create_promise(env, &c->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "timbravaTags", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteTags, CompleteTags, c, &c->work);
    napi_queue_async_work(env, c->work);
    return promise;
}

// ---------------- 文件内容摘要 SHA-256(napi 异步工作,Promise 返回) ----------------
// 曲库内容身份原语(0.12.0):fd 契约与 analyzeFd 一致——调用方保持 fd 打开至 Promise 完成。
// pread 分块读(非 mmap):数 GB DSD 文件不整段进 page cache;读至 EOF,长度以实际读到的为准。

struct HashCarrier {
    int fd = -1;
    bool ok = false;
    std::string errMsg;
    std::string hex; // 64 位小写 hex;失败时为空串(调用方以空串=无身份处理)
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteHash(napi_env env, void *data)
{
    (void)env;
    HashCarrier *c = static_cast<HashCarrier *>(data);
    OH_CryptoDigest *ctx = nullptr;
    Crypto_DataBlob out = {nullptr, 0};
    do {
        if (c->fd < 0) {
            c->errMsg = "bad fd";
            break;
        }
        if (OH_CryptoDigest_Create("SHA256", &ctx) != CRYPTO_SUCCESS) {
            c->errMsg = "digest create fail";
            break;
        }
        static constexpr size_t kChunk = 8u * 1024u * 1024u;
        std::vector<uint8_t> buf(kChunk);
        off_t off = 0;
        bool ioError = false;
        for (;;) {
            ssize_t n = ::pread(c->fd, buf.data(), kChunk, off);
            if (n < 0) {
                if (errno == EINTR) {
                    continue;
                }
                c->errMsg = "pread fail";
                ioError = true;
                break;
            }
            if (n == 0) {
                break; // EOF
            }
            Crypto_DataBlob in = {buf.data(), static_cast<size_t>(n)};
            if (OH_CryptoDigest_Update(ctx, &in) != CRYPTO_SUCCESS) {
                c->errMsg = "digest update fail";
                ioError = true;
                break;
            }
            off += n;
        }
        if (ioError) {
            break;
        }
        if (OH_CryptoDigest_Final(ctx, &out) != CRYPTO_SUCCESS) {
            c->errMsg = "digest final fail";
            break;
        }
        static const char *kHex = "0123456789abcdef";
        c->hex.reserve(out.len * 2);
        for (size_t i = 0; i < out.len; i++) {
            c->hex.push_back(kHex[(out.data[i] >> 4) & 0xF]);
            c->hex.push_back(kHex[out.data[i] & 0xF]);
        }
        c->ok = true;
    } while (false);
    if (out.data != nullptr) {
        OH_Crypto_FreeDataBlob(&out);
    }
    if (ctx != nullptr) {
        OH_DigestCrypto_Destroy(ctx);
    }
}

static void CompleteHash(napi_env env, napi_status status, void *data)
{
    HashCarrier *c = static_cast<HashCarrier *>(data);
    napi_value result = nullptr;
    napi_create_string_utf8(env, c->hex.c_str(), NAPI_AUTO_LENGTH, &result);
    if (!c->ok) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "hashFd fail: %{public}s", c->errMsg.c_str());
    }
    napi_resolve_deferred(env, c->deferred, result);
    napi_delete_async_work(env, c->work);
    delete c;
}

static napi_value JHashFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    HashCarrier *c = new HashCarrier();
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &c->fd);
    }
    napi_value promise;
    napi_create_promise(env, &c->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "timbravaHash", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteHash, CompleteHash, c, &c->work);
    napi_queue_async_work(env, c->work);
    return promise;
}

// ---------------- 快速指纹 xxHash3-128(napi 异步工作,Promise 返回) ----------------
// 两级身份的操作层(0.13.0):fpFd 读 头/中/尾 三窗采样(≤768KB 退化为全文件) + 体积混入;
// full=true 整文件求值(fp 碰撞审计消歧用,与采样指纹不可比,仅同 mode 内比较)。
// fd 契约同 hashFd:调用方保持打开至 Promise 完成。

struct FpCarrier {
    int fd = -1;
    bool full = false;
    bool ok = false;
    std::string errMsg;
    std::string hex; // 32 位小写 hex;失败为空串(调用方以空串=无身份处理)
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteFp(napi_env env, void *data)
{
    (void)env;
    FpCarrier *c = static_cast<FpCarrier *>(data);
    if (c->fd < 0) {
        c->errMsg = "bad fd";
        return;
    }
    struct stat st {};
    if (::fstat(c->fd, &st) != 0) {
        c->errMsg = "fstat fail";
        return;
    }
    const off_t fsize = st.st_size;
    static constexpr size_t kWin = 256u * 1024u;
    static constexpr size_t kSampleTotal = 3u * kWin;
    XXH3_state_t *state = XXH3_createState();
    if (state == nullptr) {
        c->errMsg = "xxh3 state fail";
        return;
    }
    struct Range {
        off_t off;
        size_t len;
    };
    do {
        if (XXH3_128bits_reset(state) != XXH_OK) {
            c->errMsg = "xxh3 reset fail";
            break;
        }
        const uint64_t sizeLe = static_cast<uint64_t>(fsize); // 体积混入(固定 8 字节,等 fp 隐含同体积)
        if (XXH3_128bits_update(state, &sizeLe, sizeof(sizeLe)) != XXH_OK) {
            c->errMsg = "xxh3 update fail";
            break;
        }
        std::vector<Range> ranges;
        if (c->full || fsize <= static_cast<off_t>(kSampleTotal)) {
            ranges.push_back({0, static_cast<size_t>(fsize)});
        } else {
            const off_t midOff = fsize / 2 - static_cast<off_t>(kWin / 2);
            ranges.push_back({0, kWin});
            ranges.push_back({midOff, kWin});
            ranges.push_back({fsize - static_cast<off_t>(kWin), kWin});
        }
        std::vector<uint8_t> buf(kWin);
        bool ioError = false;
        for (const Range &r : ranges) {
            off_t done = 0;
            while (done < static_cast<off_t>(r.len)) {
                size_t want = r.len - static_cast<size_t>(done);
                if (want > kWin) {
                    want = kWin;
                }
                ssize_t n = ::pread(c->fd, buf.data(), want, r.off + done);
                if (n < 0) {
                    if (errno == EINTR) {
                        continue;
                    }
                    c->errMsg = "pread fail";
                    ioError = true;
                    break;
                }
                if (n == 0) {
                    c->errMsg = "unexpected eof";
                    ioError = true;
                    break;
                }
                if (XXH3_128bits_update(state, buf.data(), static_cast<size_t>(n)) != XXH_OK) {
                    c->errMsg = "xxh3 update fail";
                    ioError = true;
                    break;
                }
                done += n;
            }
            if (ioError) {
                break;
            }
        }
        if (ioError) {
            break;
        }
        const XXH128_hash_t h = XXH3_128bits_digest(state);
        static const char *kHex = "0123456789abcdef";
        const uint64_t parts[2] = {h.high64, h.low64};
        c->hex.reserve(32);
        for (int p = 0; p < 2; p++) {
            for (int b = 7; b >= 0; b--) {
                const uint8_t byte = static_cast<uint8_t>((parts[p] >> (b * 8)) & 0xFF);
                c->hex.push_back(kHex[(byte >> 4) & 0xF]);
                c->hex.push_back(kHex[byte & 0xF]);
            }
        }
        c->ok = true;
    } while (false);
    XXH3_freeState(state);
}

static void CompleteFp(napi_env env, napi_status status, void *data)
{
    (void)status;
    FpCarrier *c = static_cast<FpCarrier *>(data);
    napi_value result = nullptr;
    napi_create_string_utf8(env, c->hex.c_str(), NAPI_AUTO_LENGTH, &result);
    if (!c->ok) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "fingerprintFd fail: %{public}s", c->errMsg.c_str());
    }
    napi_resolve_deferred(env, c->deferred, result);
    napi_delete_async_work(env, c->work);
    delete c;
}

static napi_value JFingerprintFd(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    FpCarrier *c = new FpCarrier();
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &c->fd);
    }
    if (argc >= 2) {
        napi_get_value_bool(env, args[1], &c->full);
    }
    napi_value promise;
    napi_create_promise(env, &c->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "timbravaFp", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteFp, CompleteFp, c, &c->work);
    napi_queue_async_work(env, c->work);
    return promise;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"openFd", nullptr, JOpenFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openNextFd", nullptr, JOpenNextFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearNextTrack", nullptr, JClearNextTrack, nullptr, nullptr, nullptr, napi_default, nullptr},
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
        {"setPeqEnabled", nullptr, JSetPeqEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPeqBand", nullptr, JSetPeqBand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setReplayGain", nullptr, JSetReplayGain, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSpeed", nullptr, JSetSpeed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSkipSilence", nullptr, JSetSkipSilence, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setBalance", nullptr, JSetBalance, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCrossfade", nullptr, JSetCrossfade, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vizSetEnabled", nullptr, JVizSetEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vizPoll", nullptr, JVizPoll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"analyzeFd", nullptr, JAnalyzeFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"envelopeFd", nullptr, JEnvelopeFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeFlacTags", nullptr, JWriteFlacTags, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hashFd", nullptr, JHashFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fingerprintFd", nullptr, JFingerprintFd, nullptr, nullptr, nullptr, napi_default, nullptr},
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
