const manager = require('@cloudbase/manager-node');
const crypto = require('node:crypto');

const env = process.env.CLOUDBASE_ENV_ID;
const service = manager.init({ envId: env, secretId: process.env.TENCENTCLOUD_SECRETID, secretKey: process.env.TENCENTCLOUD_SECRETKEY, token: process.env.TENCENTCLOUD_SESSIONTOKEN });

function fail(message) { return { ok: false, message }; }
function hash(value) { return crypto.createHash('sha256').update(`${process.env.DEVICE_HASH_SALT}:${value}`).digest('hex'); }

exports.main = async (event) => {
  const username = typeof event?.username === 'string' ? event.username.trim() : '';
  const password = typeof event?.password === 'string' ? event.password.toLowerCase() : '';
  const device = event?.device && typeof event.device === 'object' ? event.device : {};
  const deviceId = typeof device.identifier === 'string' ? device.identifier.trim() : '';
  const platform = device.platform === 'android' ? 'android' : 'web';
  if (!/^[A-Za-z0-9][A-Za-z0-9._:+@-]{4,23}$/.test(username)) return fail('账号需为 5–24 位字母、数字或连接符。');
  if (!/^[a-z0-9]{8,32}$/.test(password)) return fail('密码需为 8–32 位英文字母或数字，且不区分大小写。');
  if (username.toLowerCase() === password) return fail('账号和密码不能完全相同。');
  if (!deviceId) return fail('没有取得设备登记标识，请刷新后重试。');
  const ip = typeof event?.clientIp === 'string' ? event.clientIp : 'unknown';
  const ipHash = hash(ip);
  const marker = `d:${hash(deviceId).slice(0, 16)}`;
  const ipMarker = `i:${ipHash.slice(0, 16)}`;
  let created;
  try {
    created = await service.currentEnvironment().getUserService().createUser({ name: username, password, type: 'externalUser', userStatus: 'ACTIVE', nickName: username, description: `${marker}|${ipMarker}` });
  } catch (error) {
    return fail(error instanceof Error ? error.message : '账号创建失败，请检查账号是否已存在。');
  }
  const uid = created?.Data?.Uid;
  if (typeof uid !== 'string' || uid.length === 0) return fail('账号创建结果无效，请稍后重试。');
  return { ok: true };
};
