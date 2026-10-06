import { Device } from '@capacitor/device';
import { Capacitor } from '@capacitor/core';

export async function registrationDevice(): Promise<{identifier:string;platform:string}> {
  if (Capacitor.isNativePlatform()) {
    const {identifier} = await Device.getId();
    return {identifier,platform:'android'};
  }
  const key='fc-registration-device';
  let identifier=localStorage.getItem(key);
  if (!identifier) {identifier=crypto.randomUUID();localStorage.setItem(key,identifier)}
  return {identifier,platform:'web'};
}
