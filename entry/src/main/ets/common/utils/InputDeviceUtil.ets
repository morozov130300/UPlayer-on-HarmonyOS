import { inputDevice } from '@kit.InputKit'
import { BusinessError } from '@kit.BasicServicesKit'
import Logger from './Logger'

const TAG: string = 'InputDeviceUtil'

// AppStorage 键：是否存在指针设备（鼠标/触控板）。
// 「底部栏触摸指示=自动检测」依赖此值：有指针设备（鸿蒙 PC、外接触控板）→ 白色蒙版；否则 → 关。
export const KEY_HAS_POINTER_DEVICE: string = 'uplayer_has_pointer_device'

// 判断某个输入设备是否属于指针设备（鼠标/触控板）
function isPointerDeviceData(data: inputDevice.InputDeviceData): boolean {
  const sources: Array<inputDevice.SourceType> = data.sources
  for (let i = 0; i < sources.length; i++) {
    if (sources[i] === 'mouse' || sources[i] === 'touchpad') {
      return true
    }
  }
  return false
}

// 异步遍历当前所有输入设备，检测是否存在鼠标/触控板，结果写入 AppStorage。
// PC（2in1）自带触控板/鼠标，普通手机无鼠标时返回 false。
export function refreshPointerDeviceState(): void {
  try {
    inputDevice.getDeviceList().then((ids: Array<number>) => {
      const checks: Array<Promise<boolean>> = []
      for (let i = 0; i < ids.length; i++) {
        const id: number = ids[i]
        checks.push(inputDevice.getDeviceInfo(id).then((info: inputDevice.InputDeviceData) => {
          return isPointerDeviceData(info)
        }).catch((error: BusinessError) => {
          Logger.error(TAG, `getDeviceInfo ${id} failed: ${error.message}`)
          return false
        }))
      }
      Promise.all(checks).then((results: Array<boolean>) => {
        let has: boolean = false
        for (let i = 0; i < results.length; i++) {
          if (results[i]) {
            has = true
            break
          }
        }
        AppStorage.setOrCreate(KEY_HAS_POINTER_DEVICE, has)
      })
    }).catch((error: BusinessError) => {
      Logger.error(TAG, `getDeviceList failed: ${error.message}`)
    })
  } catch (error) {
    Logger.error(TAG, `refreshPointerDeviceState exception: ${(error as BusinessError).message}`)
  }
}

// 监听输入设备热插拔：插入/拔出鼠标、触控板时实时刷新检测结果。
// 重复调用安全：内部保证只注册一次监听。
let pointerDeviceListenerRegistered: boolean = false

export function startPointerDeviceListener(): void {
  if (pointerDeviceListenerRegistered) {
    return
  }
  try {
    inputDevice.on('change', (data: inputDevice.DeviceListener) => {
      refreshPointerDeviceState()
    })
    pointerDeviceListenerRegistered = true
  } catch (error) {
    Logger.error(TAG, `startPointerDeviceListener exception: ${(error as BusinessError).message}`)
  }
}
