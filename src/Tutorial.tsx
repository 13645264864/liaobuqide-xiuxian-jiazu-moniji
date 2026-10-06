import {useState} from 'react';import {ChevronLeft,ChevronRight,CheckCircle2} from 'lucide-react';
const lessons=[
 ['第一步 · 在宗族入世','有立族名额时可创建家族并成为族长；名额满后，选择真人道侣的子女名额入世。你出生在本族宅邸，家族不是浮在地图外的。','入世后，先看修行页的境界、灵气和所在地。'],
 ['第二步 · 领取装备和心法','储物 → 随身装备 → 领取初始衣装。选择剑、衣服等部位并点击穿戴。修行 → 妙法查看无名心法和无名战技，初次已默认装备。','无名心法在练气、筑基提供10倍修炼速度；佩剑后无名战技提高伤害。'],
 ['第三步 · 闭关与突破','城内安全闭关，点击结算闭关领取灵气。满本层需求后，在突破页提升层数；九层通过判定妖魔晋升下一境界。品级越高基础属性越高，九品为一品的150%。','野外无阵法时自动停止。金刚阵需要合成，筑基以上才能使用。'],
 ['第四步 · 探索与打怪','大世界点击格子或右侧地点自动寻路。荒原、官道每5秒判定遇怪，战斗自动弹窗。战斗中可使用疗伤丹、回灵丹和符箓，胜利获得灵石及兽皮、兽血。','初始10份引妖散在野外或官道使用，遇怪率变为100%，离开该区域失效。'],
 ['第五步 · 采集与制作','先走到本族灵矿，再在家族工坊挖矿；药草与纸材到本族灵田采集。材料进入储物。炼器需要铁砧和铁锤，炼丹需要炉鼎；到对应设施后按配方制作。','前期装备只需矿石与兽皮；制作消耗神识及材料，失败也会消耗。'],
 ['第六步 · 符箓与自创功法','符纸由纸材制作，兽血制作烈火符、雷击符。创作功法先制作观星台和人体穴位图，前往练功房；每日最多十本。功法手稿在储物里学习。','神识用于研习与制作；心境圆满增加修炼、恢复和成功率。'],
 ['第七步 · 结交与传承','底部世界聊天条直接显示最新消息，点击即可传音；点击聊天头像查看资料。家族中邀请道侣，自愿成婚后生成两个子女名额，额外名额任一父母同意即可。','更多 → 个人主页可修改头像与介绍；坐化永久注销游戏账号，立族资格会释放，族谱仍保留。']
];
export function Tutorial(){const [page,setPage]=useState(0);return <section className="tutorial"><p className="eyebrow">入世手册 · {page+1}/{lessons.length}</p><h2>{lessons[page][0]}</h2><div className="tutorial-art"><img src="monsters/core_ice_luan.png" alt="霜翼冰鸾"/><BookMark/></div><p>{lessons[page][1]}</p><div className="tutorial-tip"><CheckCircle2 size={18}/><p>{lessons[page][2]}</p></div><div className="page-controls"><button disabled={page===0} onClick={()=>setPage(p=>p-1)}><ChevronLeft size={16}/>上一步</button><span>{page+1} / {lessons.length}</span><button disabled={page===lessons.length-1} onClick={()=>setPage(p=>p+1)}>下一步<ChevronRight size={16}/></button></div></section>}
function BookMark(){return <span>仙途初启</span>}
