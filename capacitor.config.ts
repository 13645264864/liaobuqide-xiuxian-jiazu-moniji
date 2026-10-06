import type { CapacitorConfig } from '@capacitor/cli';
const config: CapacitorConfig = {
  appId: 'com.xiuxian.family.simulator',
  appName: '了不起的修仙家族模拟器',
  webDir: 'dist',
  server: { androidScheme: 'https' },
  android: { backgroundColor: '#F3EBDD' }
};
export default config;
