import { inputDevice } from '@kit.InputKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import Logger from './Logger'

const TAG: string = 'InputDeviceUtil'

// AppStorage 键：是否存在指针设备（鼠标/触控板）。
// 「底部栏触摸指示」的「白色蒙版」开关依赖此值显隐：有指针设备才显示，否则隐藏。
export const KEY_HAS_POINTER_DEVICE: string = 'uplayer_has_pointer_device'

// 设备形态本身是否「一定有鼠标光标」：鸿蒙 PC（2in1）自带触控板/鼠标，开关始终显示。
// 只认设备形态，不查输入设备列表，避免个别机型列表异常导致开关消失。
function hasBuiltInPointer(): boolean {
  return deviceInfo.deviceType === '2in1'
}

// 输入能力里是否声明了鼠标/触控板
function declaresPointer(sources: Array<inputDevice.SourceType>): boolean {
  for (let i = 0; i < sources.length; i++) {
    if (sources[i] === 'mouse' || sources[i] === 'touchpad') {
      return true
    }
  }
  return false
}

// 判断某个输入设备是否为「真实」指针设备（鼠标/触控板）：
// 1) 输入能力里必须包含 mouse 或 touchpad；
// 2) 必须是挂载在真实总线上的设备（bus 非 0）。
// 华为手机把指纹滑动传感器注册成了名为 hw_fingerprint_mouse 的 mouse 设备
// （deviceType=MOUSE、bus=0、无厂商/产品号），它没有鼠标光标，不能算指针设备；
// 真实外接鼠标（USB/蓝牙/星闪）与内置触控板（i2c/uart）都带非 0 总线号。
function isRealPointerDevice(info: inputDevice.InputDeviceData): boolean {
  const sources: Array<inputDevice.SourceType> = info.sources
  if (sources === undefined || !declaresPointer(sources)) {
    return false
  }
  if (info.bus === 0) {
    Logger.info(TAG, `ignore built-in pseudo pointer device: ${info.name}`)
    return false
  }
  return true
}

// 异步遍历当前所有输入设备，检测是否存在真实鼠标/触控板，结果写入 AppStorage。
// PC（2in1）自带鼠标光标，恒为 true；手机/平板无外接鼠标/触控板时为 false。
export function refreshPointerDeviceState(): void {
  if (hasBuiltInPointer()) {
    AppStorage.setOrCreate(KEY_HAS_POINTER_DEVICE, true)
    return
  }
  try {
    inputDevice.getDeviceList().then((ids: Array<number>) => {
      const checks: Array<Promise<boolean>> = []
      for (let i = 0; i < ids.length; i++) {
        const id: number = ids[i]
        checks.push(inputDevice.getDeviceInfo(id).then((info: inputDevice.InputDeviceData) => {
          return isRealPointerDevice(info)
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
        Logger.info(TAG, `refreshPointerDeviceState result: hasPointerDevice=${has}`)
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