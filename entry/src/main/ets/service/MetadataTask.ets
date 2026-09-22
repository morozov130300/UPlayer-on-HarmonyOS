import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { taskpool } from '@kit.ArkTS'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import Logger from '../common/utils/Logger'
import uplayer from 'libuplayer.so'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'MetadataTask'

// 封面提取结果（主线程消费）：
// ok=true 时 tempPath 指向沙箱内已写好的封面 JPEG 临时文件（消费方用完必须 unlink）
// none=true 时表示确认文件无嵌入封面（调用方进入负缓存）
// 两者皆否表示提取失败（可重试），errorMessage 带回原因
export class CoverDataResult {
  ok: boolean = false
  none: boolean = false
  tempPath: string = ''
  errorMessage: string = ''
}

// TaskPool 并行元数据提取：
// - fd 由主线程打开（规避子线程直接打开 content:// URI 的权限/兼容性问题），fd 进程内可跨线程使用
// - 任务体内使用扁平 async/await，不使用 then 链闭包（@Concurrent 场景的已知风险写法）
// - 返回 JSON 字符串（可序列化）；失败时通过 'error' 字段带回原因供主线程记录
@Concurrent
async function extractMetadataTask(fd: number): Promise<string> {
  const record: Record<string, string> = {}
  let extractor: media.AVMetadataExtractor | undefined = undefined
  try {
    const fileSize: number = fs.statSync(fd).size
    extractor = await media.createAVMetadataExtractor()
    const avFd: media.AVFileDescriptor = { fd: fd, offset: 0, length: fileSize }
    extractor.fdSrc = avFd
    const metadata: media.AVMetadata = await extractor.fetchMetadata()
    if (metadata.title !== undefined) {
      const v: string = '' + metadata.title
      if (v.length > 0) {
        record['title'] = v
      }
    }
    if (metadata.artist !== undefined) {
      const v: string = '' + metadata.artist
      if (v.length > 0) {
        record['artist'] = v
      }
    }
    if (metadata.album !== undefined) {
      const v: string = '' + metadata.album
      if (v.length > 0) {
        record['album'] = v
      }
    }
    if (metadata.duration !== undefined) {
      const v: number = Number(metadata.duration)
      if (v > 0) {
        record['duration'] = '' + v
      }
    }
    if (metadata.genre !== undefined) {
      const v: string = '' + metadata.genre
      if (v.length > 0) {
        record['genre'] = v
      }
    }
    if (metadata.trackCount !== undefined) {
      const v: string = '' + metadata.trackCount
      if (v.length > 0) {
        record['track'] = v
      }
    }
    if (metadata.sampleRate !== undefined) {
      const v: string = '' + metadata.sampleRate
      if (v.length > 0) {
        record['sampleRate'] = v
      }
    }
    if (metadata.composer !== undefined) {
      const v: string = '' + metadata.composer
      if (v.length > 0) {
        record['composer'] = v
      }
    }
    if (metadata.albumArtist !== undefined) {
      const v: string = '' + metadata.albumArtist
      if (v.length > 0) {
        record['albumArtist'] = v
      }
    }
    if (metadata.author !== undefined) {
      const v: string = '' + metadata.author
      if (v.length > 0) {
        record['author'] = v
      }
    }
    if (metadata.dateTime !== undefined) {
      const v: string = '' + metadata.dateTime
      if (v.length > 0) {
        record['dateTime'] = v
      }
    }
    if (metadata.dateTimeFormat !== undefined) {
      const v: string = '' + metadata.dateTimeFormat
      if (v.length > 0) {
        record['dateTime'] = v
      }
    }
    if (metadata.description !== undefined) {
      const v: string = '' + metadata.description
      if (v.length > 0) {
        record['description'] = v
      }
    }
    if (metadata.encoder !== undefined) {
      const v: string = '' + metadata.encoder
      if (v.length > 0) {
        record['encoder'] = v
      }
    }
    if (metadata.mimeType !== undefined) {
      const v: string = '' + metadata.mimeType
      if (v.length > 0) {
        record['mimeType'] = v
      }
    }
    if (metadata.hasAudio !== undefined) {
      const v: string = '' + metadata.hasAudio
      if (v.length > 0) {
        record['hasAudio'] = v
      }
    }
    if (metadata.hasVideo !== undefined) {
      const v: string = '' + metadata.hasVideo
      if (v.length > 0) {
        record['hasVideo'] = v
      }
    }
    if (metadata.videoWidth !== undefined) {
      const v: string = '' + metadata.videoWidth
      if (v.length > 0) {
        record['videoWidth'] = v
      }
    }
    if (metadata.videoHeight !== undefined) {
      const v: string = '' + metadata.videoHeight
      if (v.length > 0) {
        record['videoHeight'] = v
      }
    }
    if (metadata.customInfo !== undefined) {
      const custom: Record<string, string> = metadata.customInfo
      const yearVal: string | undefined = custom['originaldate'] ?? custom['year'] ?? custom['TDRC']
      if (yearVal !== undefined && yearVal.length > 0) {
        record['year'] = yearVal
      }
      const discVal: string | undefined = custom['partofaset'] ?? custom['TDIS']
      if (discVal !== undefined && discVal.length > 0) {
        record['disc'] = discVal
      }
      const commentVal: string | undefined = custom['comment'] ?? custom['COMM']
      if (commentVal !== undefined && commentVal.length > 0) {
        record['comment'] = commentVal
      }
      const languageVal: string | undefined = custom['language'] ?? custom['TLAN']
      if (languageVal !== undefined && languageVal.length > 0) {
        record['language'] = languageVal
      }
    }
    return JSON.stringify(record)
  } catch (err) {
    const errRecord: Record<string, string> = {}
    errRecord['error'] = `${JSON.stringify(err)}`.substring(0, 400)
    return JSON.stringify(errRecord)
  } finally {
    if (extractor !== undefined) {
      try {
        await extractor.release()
      } catch (err) {
      }
    }
  }
}

// 在 TaskPool 中提取单个音频文件的元数据；失败返回 undefined 并记录错误
export function extractSongMetadata(uri: string): Promise<Record<string, string> | undefined> {
  let file: fs.File
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
  } catch (err) {
    Logger.error(TAG, `open failed uri=${uri}: ${JSON.stringify(err)}`)
    return Promise.resolve(undefined)
  }
  const openedFile: fs.File = file
  return taskpool.execute(extractMetadataTask, openedFile.fd).then((raw: Object) => {
    const text: string = raw as string
    let record: Record<string, string> | undefined = undefined
    try {
      record = JSON.parse(text) as Record<string, string>
    } catch (err) {
      Logger.error(TAG, `parse result failed: ${text.substring(0, 200)}`)
      return undefined
    }
    const errVal: string | undefined = record['error']
    if (errVal !== undefined) {
      Logger.error(TAG, `extract failed uri=${uri}: ${errVal}`)
      return undefined
    }
    return record
  }).catch((err: Error): Record<string, string> | undefined => {
    Logger.error(TAG, `taskpool execute failed uri=${uri}: ${JSON.stringify(err)}`)
    return undefined
  }).finally((): void => {
    try {
      fs.closeSync(openedFile)
    } catch (err) {
    }
  })
}

// TaskPool 并行提取 native ID3 封面：worker 内把封面字节写入沙箱临时文件，返回 JSON 结果字符串。
// 字符串是 TaskPool 已验证可靠的序列化类型（元数据任务同款方案）；此前直接回传 ArrayBuffer，
// 主线程收到的数据在本设备上无法用于 createImageSource，导致封面全量加载失败。
@Concurrent
async function extractCoverDataTask(fd: number, fileSize: number, cacheKey: string, workDir: string): Promise<string> {
  try {
    const data: ArrayBuffer | undefined = uplayer.getAlbumCover(fd, fileSize, cacheKey)
    if (data === undefined || data.byteLength === 0) {
      const noneRec: Record<string, string> = {}
      noneRec['none'] = '1'
      return JSON.stringify(noneRec)
    }
    const tempPath: string = workDir + '/cover_native_' + Date.now().toString() + '_' +
      Math.floor(Math.random() * 1000000).toString() + '.jpg'
    const tmpFile: fs.File = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(tmpFile.fd, data)
      fs.closeSync(tmpFile)
    } catch (writeErr) {
      try {
        fs.closeSync(tmpFile)
      } catch (closeErr) {
      }
      try {
        fs.unlinkSync(tempPath)
      } catch (unlinkErr) {
      }
      const writeRec: Record<string, string> = {}
      writeRec['error'] = `write temp failed: ${String(writeErr)}`.substring(0, 200)
      return JSON.stringify(writeRec)
    }
    const rec: Record<string, string> = {}
    rec['path'] = tempPath
    return JSON.stringify(rec)
  } catch (err) {
    const errRec: Record<string, string> = {}
    errRec['error'] = `${String(err)}`.substring(0, 200)
    return JSON.stringify(errRec)
  }
}

// 解析 worker 任务返回的 JSON 结果（主线程）
function parseCoverTaskResult(raw: Object, uri: string): CoverDataResult {
  const result: CoverDataResult = new CoverDataResult()
  let record: Record<string, string> | undefined = undefined
  try {
    record = JSON.parse(raw as string) as Record<string, string>
  } catch (err) {
    result.errorMessage = `result parse failed uri=${uri}: ${String(raw).substring(0, 120)}`
    return result
  }
  if (record === undefined) {
    result.errorMessage = `result is null uri=${uri}`
    return result
  }
  const errVal: string | undefined = record['error']
  if (errVal !== undefined) {
    result.errorMessage = errVal
    return result
  }
  if (record['none'] !== undefined) {
    result.none = true
    return result
  }
  const pathVal: string | undefined = record['path']
  if (pathVal !== undefined && pathVal.length > 0) {
    result.ok = true
    result.tempPath = pathVal
    return result
  }
  result.errorMessage = 'unexpected result'
  return result
}

// 封面临时文件目录：优先 UIAbilityContext.filesDir，缺省回退标准沙箱路径
function coverWorkDir(): string {
  const ctx: common.UIAbilityContext | undefined =
    AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  return ctx?.filesDir ?? '/data/storage/el2/base/haps/entry/files'
}

// native ID3 封面提取（主线程开 fd 传 fd，任务在 worker 中并行执行）
export function extractCoverData(uri: string): Promise<CoverDataResult> {
  const failed: CoverDataResult = new CoverDataResult()
  let file: fs.File
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
  } catch (err) {
    Logger.error(TAG, `cover open failed uri=${uri}: ${JSON.stringify(err)}`)
    failed.errorMessage = 'open failed'
    return Promise.resolve(failed)
  }
  const openedFile: fs.File = file
  let fileSize: number = 0
  try {
    fileSize = fs.statSync(openedFile.fd).size
  } catch (err) {
    Logger.error(TAG, `cover stat failed uri=${uri}: ${JSON.stringify(err)}`)
    try {
      fs.closeSync(openedFile)
    } catch (closeErr) {
    }
    failed.errorMessage = 'stat failed'
    return Promise.resolve(failed)
  }
  return taskpool.execute(extractCoverDataTask, openedFile.fd, fileSize, uri, coverWorkDir())
    .then((raw: Object): CoverDataResult => parseCoverTaskResult(raw, uri))
    .catch((err: Error): CoverDataResult => {
      const result: CoverDataResult = new CoverDataResult()
      result.errorMessage = String(err)
      Logger.error(TAG, `cover taskpool failed uri=${uri}: ${String(err)}`)
      return result
    }).finally((): void => {
      try {
        fs.closeSync(openedFile)
      } catch (closeErr) {
      }
    })
}

// TaskPool 并行提取 fallback 封面（AVMetadataExtractor）：
// worker 内缩放封装为 JPEG（最长边 640）并写入沙箱临时文件，返回 JSON 结果字符串：
// path=成功；none=确认无嵌入封面；error=异常（可重试）
@Concurrent
async function fetchFallbackCoverTask(fd: number, fileSize: number, workDir: string): Promise<string> {
  let extractor: media.AVMetadataExtractor | undefined = undefined
  let cover: image.PixelMap | undefined = undefined
  try {
    extractor = await media.createAVMetadataExtractor()
    const avFd: media.AVFileDescriptor = { fd: fd, offset: 0, length: fileSize }
    extractor.fdSrc = avFd
    cover = await extractor.fetchAlbumCover()
    if (cover === undefined) {
      const noneRec: Record<string, string> = {}
      noneRec['none'] = '1'
      return JSON.stringify(noneRec)
    }
    const info: image.ImageInfo = await cover.getImageInfo()
    const longEdge: number = Math.max(info.size.width, info.size.height)
    if (longEdge > 640) {
      const scale: number = 640 / longEdge
      await cover.scale(scale, scale, image.AntiAliasingLevel.HIGH)
    }
    const packer: image.ImagePacker = image.createImagePacker()
    try {
      const options: image.PackingOption = { format: 'image/jpeg', quality: 90 }
      const data: ArrayBuffer = await packer.packToData(cover, options)
      const tempPath: string = workDir + '/cover_fallback_' + Date.now().toString() + '_' +
        Math.floor(Math.random() * 1000000).toString() + '.jpg'
      const tmpFile: fs.File = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      try {
        fs.writeSync(tmpFile.fd, data)
        fs.closeSync(tmpFile)
      } catch (writeErr) {
        try {
          fs.closeSync(tmpFile)
        } catch (closeErr) {
        }
        try {
          fs.unlinkSync(tempPath)
        } catch (unlinkErr) {
        }
        const writeRec: Record<string, string> = {}
        writeRec['error'] = `write temp failed: ${String(writeErr)}`.substring(0, 200)
        return JSON.stringify(writeRec)
      }
      const rec: Record<string, string> = {}
      rec['path'] = tempPath
      return JSON.stringify(rec)
    } finally {
      packer.release()
    }
  } catch (err) {
    const errRec: Record<string, string> = {}
    errRec['error'] = `${String(err)}`.substring(0, 200)
    return JSON.stringify(errRec)
  } finally {
    if (cover !== undefined) {
      cover.release()
    }
    if (extractor !== undefined) {
      try {
        await extractor.release()
      } catch (releaseErr) {
      }
    }
  }
}

// fallback 封面提取（主线程开 fd 传 fd，任务在 worker 中执行）
export function fetchFallbackCoverData(uri: string): Promise<CoverDataResult> {
  const failed: CoverDataResult = new CoverDataResult()
  let file: fs.File
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
  } catch (err) {
    Logger.error(TAG, `fallback cover open failed uri=${uri}: ${JSON.stringify(err)}`)
    failed.errorMessage = 'open failed'
    return Promise.resolve(failed)
  }
  const openedFile: fs.File = file
  let fileSize: number = 0
  try {
    fileSize = fs.statSync(openedFile.fd).size
  } catch (err) {
    Logger.error(TAG, `fallback cover stat failed uri=${uri}: ${JSON.stringify(err)}`)
    try {
      fs.closeSync(openedFile)
    } catch (closeErr) {
    }
    failed.errorMessage = 'stat failed'
    return Promise.resolve(failed)
  }
  return taskpool.execute(fetchFallbackCoverTask, openedFile.fd, fileSize, coverWorkDir())
    .then((raw: Object): CoverDataResult => parseCoverTaskResult(raw, uri))
    .catch((err: Error): CoverDataResult => {
      const result: CoverDataResult = new CoverDataResult()
      result.errorMessage = String(err)
      Logger.error(TAG, `fallback cover taskpool failed uri=${uri}: ${String(err)}`)
      return result
    }).finally((): void => {
      try {
        fs.closeSync(openedFile)
      } catch (closeErr) {
      }
    })
}

// 将提取结果应用到 SongInfo（仅在主线程调用）
export function applyMetadataToSong(song: SongInfo, record: Record<string, string>): void {
  const titleVal: string | undefined = record['title']
  if (titleVal !== undefined && titleVal.length > 0) {
    song.title = titleVal
  }
  const artistVal: string | undefined = record['artist']
  if (artistVal !== undefined && artistVal.length > 0) {
    song.artist = artistVal
  }
  const albumVal: string | undefined = record['album']
  if (albumVal !== undefined && albumVal.length > 0) {
    song.album = albumVal
  }
  const durationVal: string | undefined = record['duration']
  if (durationVal !== undefined) {
    const durationNum: number = Number(durationVal)
    if (durationNum > 0) {
      song.duration = durationNum
    }
  }
  const genreVal: string | undefined = record['genre']
  if (genreVal !== undefined && genreVal.length > 0) {
    song.genre = genreVal
  }
  const trackVal: string | undefined = record['track']
  if (trackVal !== undefined && trackVal.length > 0) {
    song.track = trackVal
  }
  const sampleRateVal: string | undefined = record['sampleRate']
  if (sampleRateVal !== undefined && sampleRateVal.length > 0) {
    const rateNum: number = parseInt(sampleRateVal)
    if (!isNaN(rateNum)) {
      song.sampleRate = rateNum
    }
  }
  const composerVal: string | undefined = record['composer']
  if (composerVal !== undefined && composerVal.length > 0) {
    song.composer = composerVal
  }
  const albumArtistVal: string | undefined = record['albumArtist']
  if (albumArtistVal !== undefined && albumArtistVal.length > 0) {
    song.albumArtist = albumArtistVal
  }
  const authorVal: string | undefined = record['author']
  if (authorVal !== undefined && authorVal.length > 0) {
    song.author = authorVal
  }
  const dateTimeVal: string | undefined = record['dateTime']
  if (dateTimeVal !== undefined && dateTimeVal.length > 0) {
    song.dateTime = dateTimeVal
  }
  const descriptionVal: string | undefined = record['description']
  if (descriptionVal !== undefined && descriptionVal.length > 0) {
    song.description = descriptionVal
  }
  const encoderVal: string | undefined = record['encoder']
  if (encoderVal !== undefined && encoderVal.length > 0) {
    song.encoder = encoderVal
  }
  const mimeTypeVal: string | undefined = record['mimeType']
  if (mimeTypeVal !== undefined && mimeTypeVal.length > 0) {
    song.mimeType = mimeTypeVal
  }
  const hasAudioVal: string | undefined = record['hasAudio']
  if (hasAudioVal !== undefined && hasAudioVal.length > 0) {
    song.hasAudio = hasAudioVal
  }
  const hasVideoVal: string | undefined = record['hasVideo']
  if (hasVideoVal !== undefined && hasVideoVal.length > 0) {
    song.hasVideo = hasVideoVal
  }
  const videoWidthVal: string | undefined = record['videoWidth']
  if (videoWidthVal !== undefined && videoWidthVal.length > 0) {
    song.videoWidth = videoWidthVal
  }
  const videoHeightVal: string | undefined = record['videoHeight']
  if (videoHeightVal !== undefined && videoHeightVal.length > 0) {
    song.videoHeight = videoHeightVal
  }
  const yearVal: string | undefined = record['year']
  if (yearVal !== undefined && yearVal.length > 0) {
    song.year = yearVal
  }
  const discVal: string | undefined = record['disc']
  if (discVal !== undefined && discVal.length > 0) {
    song.disc = discVal
  }
  const commentVal: string | undefined = record['comment']
  if (commentVal !== undefined && commentVal.length > 0) {
    song.comment = commentVal
  }
  const languageVal: string | undefined = record['language']
  if (languageVal !== undefined && languageVal.length > 0) {
    song.language = languageVal
  }
}
