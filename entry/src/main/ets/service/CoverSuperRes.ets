// 26-5 封面超分(Core Vision ImageSR):嵌入封面短边 < 500px 的曲目,全屏播放页实时超分展示。
// 守卫:26 设备(sdkApiVersion)+ VisionBase syscap 双检;24 设备 available()=false 原图直出。
// 结果按曲目缓存一份(单槽,切曲即换);失败静默降级(告警日志),不阻塞封面显示。
import { image } from '@kit.ImageKit';
import { imageSuperResolution, visionBase } from '@kit.CoreVisionKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openTargetOf } from '../common/PathUtil';

const TAG = '[Timbrava][CoverSR]';
const DOMAIN = 0x0001;

const MIN_SIDE_VP = 500; // 短边小于该像素才超分(嵌入小封面)

export class CoverSuperRes {
  private static instance: CoverSuperRes | null = null;
  static get(): CoverSuperRes {
    if (CoverSuperRes.instance === null) {
      CoverSuperRes.instance = new CoverSuperRes();
    }
    return CoverSuperRes.instance;
  }

  private analyzer: imageSuperResolution.ImageSRAnalyzer | null = null;
  private supported: boolean = deviceInfo.sdkApiVersion >= 26 &&
    canIUse('SystemCapability.AI.Vision.VisionBase');
  private lastKey: string = '';
  private lastPm: image.PixelMap | null = null;
  private inflight: Promise<image.PixelMap | null> | null = null;

  available(): boolean {
    return this.supported;
  }

  // 失败/不支持/封面够大 → null(调用方回退原图)
  async superRes(songKey: string, artPath: string): Promise<image.PixelMap | null> {
    if (!this.supported || artPath.length === 0) {
      return null;
    }
    if (this.lastKey === songKey && this.lastPm !== null) {
      return this.lastPm;
    }
    if (this.inflight !== null) {
      return this.inflight;
    }
    this.inflight = this.run(songKey, artPath);
    const r = await this.inflight;
    this.inflight = null;
    return r;
  }

  private async run(key: string, artPath: string): Promise<image.PixelMap | null> {
    let src: image.ImageSource | null = null;
    let inputPm: image.PixelMap | null = null;
    try {
      src = image.createImageSource(openTargetOf(artPath));
      if (src === null) {
        return null;
      }
      const info = await src.getImageInfo();
      const side = Math.min(info.size.width, info.size.height);
      if (side <= 0 || side >= MIN_SIDE_VP) {
        return null; // 封面已够大,无需超分
      }
      inputPm = await src.createPixelMap();
      if (this.analyzer === null) {
        this.analyzer = await imageSuperResolution.ImageSRAnalyzer.create();
      }
      const req: visionBase.Request = { inputData: { pixelMap: inputPm } };
      const resp = await this.analyzer.process(req) as imageSuperResolution.ISPResponse;
      if (resp === null || resp.pixelMap === null) {
        return null;
      }
      this.lastKey = key;
      this.lastPm = resp.pixelMap;
      hilog.info(DOMAIN, TAG, 'sr ok %{public}dx%{public}d -> sr', info.size.width, info.size.height);
      return this.lastPm;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'sr fail %{public}s', (e as Error).message);
      if ((e as Error).message.indexOf('801') >= 0) {
        this.supported = false; // 能力不支持,后续直接短路
      }
      return null;
    } finally {
      if (src !== null) {
        try {
          await src.release();
        } catch (e) {
        }
      }
      if (inputPm !== null) {
        try {
          await inputPm.release();
        } catch (e) {
        }
      }
    }
  }
}
