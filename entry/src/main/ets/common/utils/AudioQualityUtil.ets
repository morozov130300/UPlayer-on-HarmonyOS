import { SongInfo } from '../../model/SongInfo'

// 音质等级缩写（显示在标签最前），按采样率/位深/码率从高到低判定：
// 母带：24bit 且（采样率 ≥176.4kHz 或码率 >900kbps）；Hi-Res：位深 ≥24bit（超越 CD 的 16bit）；
// SQ：无损编码或码率 ≥512kbps；HQ：码率 ≥256kbps（320kbps 有损）；Standard：其余有码率数据的有损
export function audioQualityTier(song: SongInfo): string {
  const depthRaw: string = song.bitDepth.trim()
  const depth: number = depthRaw.length > 0 && !isNaN(Number(depthRaw)) ? Number(depthRaw) : 0
  const sampleRate: number = song.sampleRate
  const bitrate: number = song.effectiveBitrate()
  const losslessCodecs: string[] = ['FLAC', 'APE', 'WAV', 'ALAC', 'AIFF', 'DSD', 'PCM']
  const codec: string = song.codec.trim().toUpperCase()
  if (depth >= 24 && (sampleRate >= 176400 || bitrate > 900000)) {
    return '母带'
  }
  if (depth >= 24) {
    return 'Hi-Res'
  }
  if (losslessCodecs.some((item: string): boolean => codec.length > 0 && codec.includes(item))) {
    return 'SQ'
  }
  if (bitrate >= 512000) {
    return 'SQ'
  }
  if (bitrate >= 256000) {
    return 'HQ'
  }
  if (bitrate > 0) {
    return 'Standard'
  }
  return ''
}

// 封面左下角音质标签：等级缩写在前，码率/采样率/位深跟随；完全无数据时不渲染
export function audioQualityBadgeText(song: SongInfo): string {
  const parts: string[] = []
  const tier: string = audioQualityTier(song)
  if (tier.length > 0) {
    parts.push(tier)
  }
  const bitrate: number = song.effectiveBitrate()
  if (bitrate > 0) {
    parts.push(`${Math.round(bitrate / 1000)} kbps`)
  }
  if (song.sampleRate > 0) {
    parts.push(`${(song.sampleRate / 1000).toFixed(1).replace(/\.0$/, '')} kHz`)
  }
  const depth: string = song.bitDepth.trim()
  if (depth.length > 0) {
    parts.push(`${depth} bit`)
  }
  return parts.join(' · ')
}
