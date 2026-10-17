import { relationalStore } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
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
  'videoHeight TEXT NOT NULL DEFAULT \'\',' +
  'channels TEXT NOT NULL DEFAULT \'\',' +
  'bitDepth TEXT NOT NULL DEFAULT \'\',' +
  'codec TEXT NOT NULL DEFAULT \'\',' +
  'trackCount TEXT NOT NULL DEFAULT \'\',' +
  'fileSize INTEGER NOT NULL DEFAULT 0)'

const SQL_INDEX_URI: string = 'CREATE INDEX IF NOT EXISTS idx_songs_uri ON songs(uri)'
const SQL_INDEX_FOLDER: string = 'CREATE INDEX IF NOT EXISTS idx_songs_folder ON songs(folderPath)'
const SQL_INDEX_SORT: string = 'CREATE INDEX IF NOT EXISTS idx_songs_sort ON songs(sortOrder)'

const TABLE_FOLDERS: string = 'folders'
const SQL_CREATE_FOLDERS: string = 'CREATE TABLE IF NOT EXISTS folders (' +
  'id TEXT PRIMARY KEY,' +
  'name TEXT NOT NULL DEFAULT \'\',' +
  'path TEXT NOT NULL DEFAULT \'\',' +
  'songCount INTEGER NOT NULL DEFAULT 0,' +
  'addedTime INTEGER NOT NULL DEFAULT 0,' +
  'isAvailable INTEGER NOT NULL DEFAULT 1,' +
  'isFavorite INTEGER NOT NULL DEFAULT 0,' +
  'sortOrder INTEGER NOT NULL DEFAULT 0,' +
  'orderIndex INTEGER NOT NULL DEFAULT 0)'

// 当前 schema 的列名清单：从上面的 CREATE TABLE SQL 常量解析生成（单一事实源）。
// v1.0.7 起不再手工维护第二份列清单——两份清单一旦漂移（给 SQL 加列忘同步数组），
// 当前 schema 的表会被误判为旧版本遗留表整表 DROP，升级用户的曲库将被清空。
// 解析结果为空说明 SQL 格式失配，直接抛错，绝不允许静默通过
// （空清单会使缺列检测永远不触发，那是反向的坑）。
function parseTableColumns(createSql: string): string[] {
  const open: number = createSql.indexOf('(')
  const close: number = createSql.lastIndexOf(')')
  if (open < 0 || close <= open) {
    throw new Error('parseTableColumns failed: malformed CREATE TABLE sql')
  }
  const columns: string[] = []
  for (const segment of createSql.substring(open + 1, close).split(',')) {
    const matched = segment.trim().match(/^(\w+)\s+(?:TEXT|INTEGER)/)
    if (matched !== null) {
      columns.push(matched[1])
    }
  }
  if (columns.length === 0) {
    throw new Error('parseTableColumns failed: no column parsed from CREATE TABLE sql')
  }
  return columns
}

const SONGS_COLUMNS: string[] = parseTableColumns(SQL_CREATE_SONGS)
const FOLDERS_COLUMNS: string[] = parseTableColumns(SQL_CREATE_FOLDERS)

// 表结构探测结果：
//   current = 列齐全，当前 schema，原样保留
//   legacy  = 缺列，旧版本遗留表，整表 DROP 重建
//   absent  = 表不存在，交给 CREATE TABLE
//   unknown = 无法得出结论（探测手段全部失败），绝不动表
interface TableProbe {
  status: 'current' | 'legacy' | 'absent' | 'unknown'
  missing: string[]
}

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
        // v1.0.7 起不跨版本兼容：先检测并清除旧版本遗留表，再执行建表
        // （CREATE TABLE IF NOT EXISTS 对已存在的旧表无效，必须先 DROP）
        await this.enforceCurrentSchema(store)
        await store.executeSql(SQL_CREATE_SONGS)
        await store.executeSql(SQL_INDEX_URI)
        await store.executeSql(SQL_INDEX_FOLDER)
        await store.executeSql(SQL_INDEX_SORT)
        await store.executeSql(SQL_CREATE_FOLDERS)
        Logger.info(TAG, 'SongDatabase initialized')
        resolve()
      }).catch((err: Error) => {
        Logger.error(TAG, `SongDatabase init failed: ${JSON.stringify(err)}`)
        reject(err)
      })
    })
    return this.initPromise
  }

  // ═══════════ 旧版本 schema 检测与清除（v1.0.7 起不跨版本兼容） ═══════════
  //
  // 【版本记录】v1.0.7 移除旧版本数据库兼容逻辑：v1.0.6 及更早版本若曾以
  // 不同列结构创建过 'uplayer.db'，覆盖安装后 CREATE TABLE IF NOT EXISTS 不会
  // 修正旧表，后续 batchInsert/UPDATE 会因缺列持续失败。自 v1.0.7 起不再
  // 兼容任何旧结构：检测到列不符的旧表即整表 DROP，由随后的 CREATE 重建，
  // 旧表数据一律视为废弃数据，不做迁移。
  //
  // 安全约束（v1.0.7 加固）：
  //   1) songs 与 folders 独立判定、独立处理，不再假设两者必然同源；
  //   2) 仅当确认真缺列时才 DROP；探测无法得出结论（unknown）时绝不动表；
  //   3) DROP 失败只记日志继续走 CREATE——schema 维护失败不应让 initPromise
  //      永久 rejected（init 失败不重试），把新安装/普通路径一起拖下水。
  private async enforceCurrentSchema(store: relationalStore.RdbStore): Promise<void> {
    const songsProbe: TableProbe = await this.probeTable(store, TABLE_SONGS, SONGS_COLUMNS)
    if (songsProbe.status === 'legacy') {
      Logger.warn(TAG, `legacy songs table detected, missing columns [${songsProbe.missing.join(', ')}], drop & recreate`)
      await this.dropTableSafely(store, TABLE_SONGS)
    } else if (songsProbe.status === 'unknown') {
      Logger.warn(TAG, 'songs schema probe inconclusive, table kept untouched')
    }
    const foldersProbe: TableProbe = await this.probeTable(store, TABLE_FOLDERS, FOLDERS_COLUMNS)
    if (foldersProbe.status === 'legacy') {
      Logger.warn(TAG, `legacy folders table detected, missing columns [${foldersProbe.missing.join(', ')}], drop & recreate`)
      await this.dropTableSafely(store, TABLE_FOLDERS)
    } else if (foldersProbe.status === 'unknown') {
      Logger.warn(TAG, 'folders schema probe inconclusive, table kept untouched')
    }
    Logger.info(TAG, `schema check: songs=${songsProbe.status}, folders=${foldersProbe.status}`)
  }

  // DROP 失败不向上抛：记录错误后由调用方继续 CREATE 流程
  private async dropTableSafely(store: relationalStore.RdbStore, table: string): Promise<void> {
    try {
      await store.executeSql(`DROP TABLE IF EXISTS ${table}`)
    } catch (err) {
      Logger.error(TAG, `DROP TABLE ${table} failed: ${JSON.stringify(err)}`)
    }
  }

  // 表结构探测。两种手段互为备份（平台 querySql 对 PRAGMA 的支持未经真机验证，
  // 单点依赖会让旧表检测静默失效、原覆盖安装问题依旧存在）：
  //   1) PRAGMA table_info：返回 0 行 = 表不存在；缺列 = legacy；
  //   2) SELECT 当前全部列：成功 = current；抛错含 no such column = legacy；
  //      含 no such table = absent。
  // 两种手段都无法得出结论时返回 unknown——调用方绝不允许据此 DROP。
  private async probeTable(store: relationalStore.RdbStore, table: string,
    expectedColumns: string[]): Promise<TableProbe> {
    try {
      const resultSet: relationalStore.ResultSet = await store.querySql(`PRAGMA table_info(${table})`)
      const columns: string[] = []
      try {
        while (resultSet.goToNextRow()) {
          const idx: number = resultSet.getColumnIndex('name')
          if (idx >= 0 && !resultSet.isColumnNull(idx)) {
            columns.push(resultSet.getString(idx))
          }
        }
      } finally {
        resultSet.close()
      }
      if (columns.length === 0) {
        return { status: 'absent', missing: [] }
      }
      const missing: string[] = expectedColumns.filter((column: string) => !columns.includes(column))
      return { status: missing.length === 0 ? 'current' : 'legacy', missing: missing }
    } catch (pragmaErr) {
      Logger.warn(TAG, `PRAGMA table_info(${table}) failed, fallback to column select: ${JSON.stringify(pragmaErr)}`)
    }
    try {
      await store.querySql(`SELECT ${expectedColumns.join(',')} FROM ${table} LIMIT 1`)
      return { status: 'current', missing: [] }
    } catch (selectErr) {
      const err: Error = selectErr as Error
      const msg: string = `${err?.message ?? ''} ${JSON.stringify(selectErr)}`
      if (msg.includes('no such column')) {
        return { status: 'legacy', missing: [] }
      }
      if (msg.includes('no such table')) {
        return { status: 'absent', missing: [] }
      }
      Logger.warn(TAG, `probe ${table} inconclusive: ${msg}`)
      return { status: 'unknown', missing: [] }
    }
  }

  public async queryAllSongs(): Promise<SongInfo[]> {
    const store = this.requireStore()
    const predicates = new relationalStore.RdbPredicates(TABLE_SONGS)
    predicates.orderByAsc('sortOrder').orderByAsc('addedTime')
    const resultSet: relationalStore.ResultSet = await store.query(predicates)
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
      const predicates = new relationalStore.RdbPredicates(TABLE_SONGS)
      predicates.in('id', chunk)
      await store.delete(predicates)
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

  // ═══════════ folders 表：文件夹列表持久化（替代 JSON-in-Preferences） ═══════════

  // 按持久化时的数组顺序（orderIndex）读回，保证与写入前的列表顺序一致
  public async queryAllFolders(): Promise<FolderInfo[]> {
    const store = this.requireStore()
    const predicates = new relationalStore.RdbPredicates(TABLE_FOLDERS)
    predicates.orderByAsc('orderIndex')
    const resultSet: relationalStore.ResultSet = await store.query(predicates)
    const result: FolderInfo[] = []
    try {
      while (resultSet.goToNextRow()) {
        result.push(this.folderFromResultSet(resultSet))
      }
    } finally {
      resultSet.close()
    }
    return result
  }

  // 全量替换：显式事务内先清空再批量插入，数组顺序由 orderIndex 记录
  public async replaceFolders(folders: FolderInfo[]): Promise<void> {
    const store = this.requireStore()
    store.beginTransaction()
    try {
      await store.executeSql(`DELETE FROM ${TABLE_FOLDERS}`)
      const buckets: relationalStore.ValuesBucket[] = []
      for (let i = 0; i < folders.length; i++) {
        buckets.push(this.folderToValuesBucket(folders[i], i))
      }
      if (buckets.length > 0) {
        await store.batchInsert(TABLE_FOLDERS, buckets)
      }
      await store.commit()
    } catch (err) {
      store.rollBack()
      throw new Error(`replaceFolders failed: ${JSON.stringify(err)}`)
    }
  }

  private folderToValuesBucket(folder: FolderInfo, orderIndex: number): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {}
    bucket['id'] = folder.id
    bucket['name'] = folder.name
    bucket['path'] = folder.path
    bucket['songCount'] = folder.songCount
    bucket['addedTime'] = folder.addedTime
    bucket['isAvailable'] = folder.isAvailable ? 1 : 0
    bucket['isFavorite'] = folder.isFavorite ? 1 : 0
    bucket['sortOrder'] = folder.sortOrder
    bucket['orderIndex'] = orderIndex
    return bucket
  }

  private folderFromResultSet(rs: relationalStore.ResultSet): FolderInfo {
    const folder: FolderInfo = new FolderInfo()
    folder.id = this.rsGetString(rs, 'id')
    folder.name = this.rsGetString(rs, 'name')
    folder.path = this.rsGetString(rs, 'path')
    folder.songCount = this.rsGetLong(rs, 'songCount')
    folder.addedTime = this.rsGetLong(rs, 'addedTime')
    folder.isAvailable = this.rsGetLong(rs, 'isAvailable') !== 0
    folder.isFavorite = this.rsGetLong(rs, 'isFavorite') !== 0
    folder.sortOrder = this.rsGetLong(rs, 'sortOrder')
    return folder
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
    bucket['channels'] = song.channels
    bucket['bitDepth'] = song.bitDepth
    bucket['codec'] = song.codec
    bucket['trackCount'] = song.trackCount
    bucket['fileSize'] = song.fileSize
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
    song.channels = this.rsGetString(rs, 'channels')
    song.bitDepth = this.rsGetString(rs, 'bitDepth')
    song.codec = this.rsGetString(rs, 'codec')
    song.trackCount = this.rsGetString(rs, 'trackCount')
    song.fileSize = this.rsGetLong(rs, 'fileSize')
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
