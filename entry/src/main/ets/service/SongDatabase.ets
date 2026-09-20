import { relationalStore } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import Logger from '../common/utils/Logger'

const TAG = 'SongDatabase'

const DB_NAME: string = 'uplayer.db'
const TABLE_SONGS: string = 'songs'
const SQL_BATCH_SIZE: number = 100

const SQL_CREATE_SONGS: string = 'CREATE TABLE IF NOT EXISTS songs (' +
  'id TEXT PRIMARY KEY,' +
  'name TEXT NOT NULL DEFAULT \'\',' +
  'title TEXT NOT NULL DEFAULT \'\',' +
  'artist TEXT NOT NULL DEFAULT \'\',' +
  'album TEXT NOT NULL DEFAULT \'\',' +
  'filePath TEXT NOT NULL DEFAULT \'\',' +
  'uri TEXT NOT NULL DEFAULT \'\',' +
  'fileName TEXT NOT NULL DEFAULT \'\',' +
  'folderPath TEXT NOT NULL DEFAULT \'\',' +
  'folderName TEXT NOT NULL DEFAULT \'\',' +
  'duration INTEGER NOT NULL DEFAULT 0,' +
  'bitrate INTEGER NOT NULL DEFAULT 0,' +
  'sampleRate INTEGER NOT NULL DEFAULT 0,' +
  'addedTime INTEGER NOT NULL DEFAULT 0,' +
  'sortOrder INTEGER NOT NULL DEFAULT 0,' +
  'isFavorite INTEGER NOT NULL DEFAULT 0,' +
  'isAvailable INTEGER NOT NULL DEFAULT 1,' +
  'lyricPath TEXT NOT NULL DEFAULT \'\',' +
  'lyricUri TEXT NOT NULL DEFAULT \'\',' +
  'genre TEXT NOT NULL DEFAULT \'\',' +
  'year TEXT NOT NULL DEFAULT \'\',' +
  'track TEXT NOT NULL DEFAULT \'\',' +
  'disc TEXT NOT NULL DEFAULT \'\',' +
  'comment TEXT NOT NULL DEFAULT \'\',' +
  'composer TEXT NOT NULL DEFAULT \'\',' +
  'conductor TEXT NOT NULL DEFAULT \'\',' +
  'albumArtist TEXT NOT NULL DEFAULT \'\',' +
  'author TEXT NOT NULL DEFAULT \'\',' +
  'language TEXT NOT NULL DEFAULT \'\',' +
  'mimeType TEXT NOT NULL DEFAULT \'\',' +
  'dateTime TEXT NOT NULL DEFAULT \'\',' +
  'encoder TEXT NOT NULL DEFAULT \'\',' +
  'description TEXT NOT NULL DEFAULT \'\',' +
  'hasAudio TEXT NOT NULL DEFAULT \'\',' +
  'hasVideo TEXT NOT NULL DEFAULT \'\',' +
  'videoWidth TEXT NOT NULL DEFAULT \'\',' +
  'videoHeight TEXT NOT NULL DEFAULT \'\')'

const SQL_INDEX_URI: string = 'CREATE INDEX IF NOT EXISTS idx_songs_uri ON songs(uri)'
const SQL_INDEX_FOLDER: string = 'CREATE INDEX IF NOT EXISTS idx_songs_folder ON songs(folderPath)'
const SQL_INDEX_SORT: string = 'CREATE INDEX IF NOT EXISTS idx_songs_sort ON songs(sortOrder)'

// 曲库关系型数据库封装：所有写入均为增量 SQL（批量 INSERT / 单行 UPDATE / 批量 DELETE），
// 禁止全表重写；批量插入使用 batchInsert（内部自带事务），更新走显式事务。
export class SongDatabase {
  private static instance: SongDatabase = new SongDatabase()
  private store: relationalStore.RdbStore | undefined = undefined
  private initPromise: Promise<void> | undefined = undefined

  public static getInstance(): SongDatabase {
    return SongDatabase.instance
  }

  public init(context: common.UIAbilityContext): Promise<void> {
    if (this.initPromise !== undefined) {
      return this.initPromise
    }
    this.initPromise = new Promise<void>((resolve: () => void, reject: (err: Error) => void) => {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      }
      relationalStore.getRdbStore(context, config).then(async (store: relationalStore.RdbStore) => {
        this.store = store
        await store.executeSql(SQL_CREATE_SONGS)
        await store.executeSql(SQL_INDEX_URI)
        await store.executeSql(SQL_INDEX_FOLDER)
        await store.executeSql(SQL_INDEX_SORT)
        Logger.info(TAG, 'SongDatabase initialized')
        resolve()
      }).catch((err: Error) => {
        Logger.error(TAG, `SongDatabase init failed: ${JSON.stringify(err)}`)
        reject(err)
      })
    })
    return this.initPromise
  }

  public async queryAllSongs(): Promise<SongInfo[]> {
    const store = this.requireStore()
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT * FROM songs ORDER BY sortOrder ASC, addedTime ASC')
    const result: SongInfo[] = []
    try {
      while (resultSet.goToNextRow()) {
        result.push(this.fromResultSet(resultSet))
      }
    } finally {
      resultSet.close()
    }
    return result
  }

  // 批量增量插入：batchInsert 内部自带事务，按 SQL_BATCH_SIZE 分批降低单次事务体积
  public async insertSongs(songs: SongInfo[]): Promise<void> {
    if (songs.length === 0) {
      return
    }
    const store = this.requireStore()
    for (let offset = 0; offset < songs.length; offset += SQL_BATCH_SIZE) {
      const chunk: SongInfo[] = songs.slice(offset, offset + SQL_BATCH_SIZE)
      const buckets: relationalStore.ValuesBucket[] = []
      for (let i = 0; i < chunk.length; i++) {
        buckets.push(this.toValuesBucket(chunk[i]))
      }
      await store.batchInsert(TABLE_SONGS, buckets)
    }
    Logger.info(TAG, `insertSongs: ${songs.length} rows inserted`)
  }

  // 批量增量删除：按主键分批 DELETE，绝不触碰未删除的行
  public async deleteSongsByIds(ids: string[]): Promise<void> {
    if (ids.length === 0) {
      return
    }
    const store = this.requireStore()
    for (let offset = 0; offset < ids.length; offset += SQL_BATCH_SIZE) {
      const chunk: string[] = ids.slice(offset, offset + SQL_BATCH_SIZE)
      const placeholders: string[] = []
      const args: Array<relationalStore.ValueType> = []
      for (let i = 0; i < chunk.length; i++) {
        placeholders.push('?')
        args.push(chunk[i])
      }
      await store.executeSql(`DELETE FROM songs WHERE id IN (${placeholders.join(', ')})`, args)
    }
    Logger.info(TAG, `deleteSongsByIds: ${ids.length} rows deleted`)
  }

  // 增量更新已变更的行：显式事务批量提交，减少 I/O 次数
  public async updateSongs(songs: SongInfo[]): Promise<void> {
    if (songs.length === 0) {
      return
    }
    const store = this.requireStore()
    store.beginTransaction()
    try {
      for (let i = 0; i < songs.length; i++) {
        const predicates = new relationalStore.RdbPredicates(TABLE_SONGS)
        predicates.equalTo('id', songs[i].id)
        await store.update(this.toValuesBucket(songs[i]), predicates)
      }
      await store.commit()
    } catch (err) {
      store.rollBack()
      throw new Error(`updateSongs failed: ${JSON.stringify(err)}`)
    }
    Logger.info(TAG, `updateSongs: ${songs.length} rows updated`)
  }

  // WAL 收敛：写事务只会让 wal 文件增长（自动 checkpoint 阈值约 1000 页），
  // 主动 TRUNCATE 把 wal 收缩到最小体积，避免「本地数据」被 wal 撑大。
  // 失败（例如存在未关闭的结果集导致 BUSY）只记日志，绝不影响业务流程。
  public async checkpoint(): Promise<void> {
    if (this.store === undefined) {
      return
    }
    try {
      await this.store.executeSql('PRAGMA wal_checkpoint(TRUNCATE)')
      Logger.info(TAG, 'wal checkpoint done')
    } catch (err) {
      Logger.warn(TAG, `wal checkpoint failed: ${JSON.stringify(err)}`)
    }
  }

  private requireStore(): relationalStore.RdbStore {
    if (this.store === undefined) {
      throw new Error('SongDatabase not initialized')
    }
    return this.store
  }

  public toValuesBucket(song: SongInfo): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {}
    bucket['id'] = song.id
    bucket['name'] = song.name
    bucket['title'] = song.title
    bucket['artist'] = song.artist
    bucket['album'] = song.album
    bucket['filePath'] = song.filePath
    bucket['uri'] = song.uri
    bucket['fileName'] = song.fileName
    bucket['folderPath'] = song.folderPath
    bucket['folderName'] = song.folderName
    bucket['duration'] = song.duration
    bucket['bitrate'] = song.bitrate
    bucket['sampleRate'] = song.sampleRate
    bucket['addedTime'] = song.addedTime
    bucket['sortOrder'] = song.sortOrder
    bucket['isFavorite'] = song.isFavorite ? 1 : 0
    bucket['isAvailable'] = song.isAvailable ? 1 : 0
    bucket['lyricPath'] = song.lyricPath
    bucket['lyricUri'] = song.lyricUri
    bucket['genre'] = song.genre
    bucket['year'] = song.year
    bucket['track'] = song.track
    bucket['disc'] = song.disc
    bucket['comment'] = song.comment
    bucket['composer'] = song.composer
    bucket['conductor'] = song.conductor
    bucket['albumArtist'] = song.albumArtist
    bucket['author'] = song.author
    bucket['language'] = song.language
    bucket['mimeType'] = song.mimeType
    bucket['dateTime'] = song.dateTime
    bucket['encoder'] = song.encoder
    bucket['description'] = song.description
    bucket['hasAudio'] = song.hasAudio
    bucket['hasVideo'] = song.hasVideo
    bucket['videoWidth'] = song.videoWidth
    bucket['videoHeight'] = song.videoHeight
    return bucket
  }

  private fromResultSet(rs: relationalStore.ResultSet): SongInfo {
    const song: SongInfo = new SongInfo()
    song.id = this.rsGetString(rs, 'id')
    song.name = this.rsGetString(rs, 'name')
    song.title = this.rsGetString(rs, 'title')
    song.artist = this.rsGetString(rs, 'artist')
    song.album = this.rsGetString(rs, 'album')
    song.filePath = this.rsGetString(rs, 'filePath')
    song.uri = this.rsGetString(rs, 'uri')
    song.fileName = this.rsGetString(rs, 'fileName')
    song.folderPath = this.rsGetString(rs, 'folderPath')
    song.folderName = this.rsGetString(rs, 'folderName')
    song.duration = this.rsGetLong(rs, 'duration')
    song.bitrate = this.rsGetLong(rs, 'bitrate')
    song.sampleRate = this.rsGetLong(rs, 'sampleRate')
    song.addedTime = this.rsGetLong(rs, 'addedTime')
    song.sortOrder = this.rsGetLong(rs, 'sortOrder')
    song.isFavorite = this.rsGetLong(rs, 'isFavorite') !== 0
    song.isAvailable = this.rsGetLong(rs, 'isAvailable') !== 0
    song.lyricPath = this.rsGetString(rs, 'lyricPath')
    song.lyricUri = this.rsGetString(rs, 'lyricUri')
    song.genre = this.rsGetString(rs, 'genre')
    song.year = this.rsGetString(rs, 'year')
    song.track = this.rsGetString(rs, 'track')
    song.disc = this.rsGetString(rs, 'disc')
    song.comment = this.rsGetString(rs, 'comment')
    song.composer = this.rsGetString(rs, 'composer')
    song.conductor = this.rsGetString(rs, 'conductor')
    song.albumArtist = this.rsGetString(rs, 'albumArtist')
    song.author = this.rsGetString(rs, 'author')
    song.language = this.rsGetString(rs, 'language')
    song.mimeType = this.rsGetString(rs, 'mimeType')
    song.dateTime = this.rsGetString(rs, 'dateTime')
    song.encoder = this.rsGetString(rs, 'encoder')
    song.description = this.rsGetString(rs, 'description')
    song.hasAudio = this.rsGetString(rs, 'hasAudio')
    song.hasVideo = this.rsGetString(rs, 'hasVideo')
    song.videoWidth = this.rsGetString(rs, 'videoWidth')
    song.videoHeight = this.rsGetString(rs, 'videoHeight')
    if (song.title.length === 0) {
      song.title = song.name
    }
    if (song.uri.length === 0) {
      song.uri = song.filePath
    }
    return song
  }

  private rsGetString(rs: relationalStore.ResultSet, column: string): string {
    const idx: number = rs.getColumnIndex(column)
    if (idx < 0 || rs.isColumnNull(idx)) {
      return ''
    }
    return rs.getString(idx)
  }

  private rsGetLong(rs: relationalStore.ResultSet, column: string): number {
    const idx: number = rs.getColumnIndex(column)
    if (idx < 0 || rs.isColumnNull(idx)) {
      return 0
    }
    return rs.getLong(idx)
  }
}
