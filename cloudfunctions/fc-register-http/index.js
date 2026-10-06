const http = require('node:http');
const crypto = require('node:crypto');
const manager = require('@cloudbase/manager-node');

const env = process.env.CLOUDBASE_ENV_ID;
const service = manager.init({ envId: env, secretId: process.env.TENCENTCLOUD_SECRETID, secretKey: process.env.TENCENTCLOUD_SECRETKEY, token: process.env.TENCENTCLOUD_SESSIONTOKEN });
const cors = {};
function reply(res,status,data){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8',...cors});res.end(JSON.stringify(data));}
function hash(v){return crypto.createHash('sha256').update(`${process.env.DEVICE_HASH_SALT}:${v}`).digest('hex').slice(0,16)}
function credentialPassword(password){let h=0x811c9dc5;for(const c of password){h^=c.charCodeAt(0);h=Math.imul(h,16777619)}return `${Math.abs(h).toString(36).padStart(8,'0')}${password.slice(0,16)}Aa1!`.slice(0,32)}
function body(req){return new Promise((resolve,reject)=>{let raw='';req.on('data',x=>{raw+=x;if(raw.length>8192)reject(new Error('body too large'))});req.on('end',()=>{try{resolve(raw?JSON.parse(raw):{})}catch{reject(new Error('invalid json'))}});req.on('error',reject)})}
const server=http.createServer(async(req,res)=>{
  if(req.method==='OPTIONS'){res.writeHead(204,cors);return res.end()}
  if(req.method!=='POST'||!['/','/register'].includes(new URL(req.url||'/', 'http://127.0.0.1').pathname))return reply(res,404,{ok:false,message:'Not Found'});
  try{
    const input=await body(req);const username=typeof input.username==='string'?input.username.trim():'';const password=typeof input.password==='string'?input.password.toLowerCase():'';const device=input.device&&typeof input.device==='object'?input.device:{};const deviceId=typeof device.identifier==='string'?device.identifier.trim():'';
    if(!/^[A-Za-z0-9][A-Za-z0-9._:+@-]{4,23}$/.test(username))return reply(res,400,{ok:false,message:'账号需为 5–24 位字母、数字或连接符。'});
    if(!/^[a-z0-9]{8,32}$/.test(password))return reply(res,400,{ok:false,message:'密码需为 8–32 位英文字母或数字，且不区分大小写。'});
    if(username.toLowerCase()===password)return reply(res,400,{ok:false,message:'账号和密码不能完全相同。'});
    if(!deviceId)return reply(res,400,{ok:false,message:'没有取得设备登记标识，请刷新后重试。'});
    const ip=String(req.headers['x-forwarded-for']||req.socket.remoteAddress||'unknown').split(',')[0].trim();
    const description=`d:${hash(deviceId)}|i:${hash(ip)}`;
    const created=await service.currentEnvironment().getUserService().createUser({name:username,password:credentialPassword(password),type:'externalUser',userStatus:'ACTIVE',nickName:username,description});
    if(!created?.Data?.Uid)return reply(res,500,{ok:false,message:'账号创建结果无效，请稍后重试。'});
    return reply(res,200,{ok:true});
  }catch(error){return reply(res,400,{ok:false,message:error instanceof Error?error.message:'注册失败，请稍后重试。'})}
});
server.listen(9000);
