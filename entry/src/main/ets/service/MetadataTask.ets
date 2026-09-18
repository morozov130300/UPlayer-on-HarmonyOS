import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { taskpool } from '@kit.ArkTS'
import { SongInfo } from '../model/SongInfo'

// TaskPool 并行元数据提取：任务运行在线程池中，返回 JSON 字符串（可序列化），
// 主线程解析后应用到 SongInfo，避免主线程串行提取导致导入缓慢。
@Concurrent
function extractMetadataTask(uri: string): Promise<string> {
  let extractor: media.AVMetadataExtractor | undefined = undefined
  let file: fs.File | undefined = undefined
  try {
    const record: Record<string, string> = {}
    return media.createAVMetadataExtractor().then(async (ext: media.AVMetadataExtractor): Promise<string> => {
      extractor = ext
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const fileSize: number = fs.statSync(file.fd).size
      const avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: fileSize }
      ext.fdSrc = avFd
      const metadata: media.AVMetadata = await ext.fetchMetadata()
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
    }).catch((_err: Error): Promise<string> | string => {
      return ''
    }).finally((): void => {
      if (extractor !== undefined) {
        extractor.release().catch((_err: Error) => {
        })
      }
      if (file !== undefined) {
        fs.closeSync(file)
      }
    })
  } catch (err) {
    return Promise.resolve('')
  }
}

// 在 TaskPool 中提取单个音频文件的元数据；失败返回 undefined
export function extractSongMetadata(uri: string): Promise<Record<string, string> | undefined> {
  return taskpool.execute(extractMetadataTask, uri).then((raw: Object) => {
    const text: string = raw as string
    if (text.length === 0) {
      return undefined
    }
    try {
      return JSON.parse(text) as Record<string, string>
    } catch (err) {
      return undefined
    }
  }).catch((_err: Error): Record<string, string> | undefined => {
    return undefined
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
