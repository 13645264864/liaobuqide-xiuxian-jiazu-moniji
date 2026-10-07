import type {WorldState} from './types';

export function roomDistances(navigation:WorldState['navigation'],start:string):Map<string,number>{
 const adjacency=new Map<string,string[]>();
 for(const edge of navigation?.edges||[]){
  const neighbors=adjacency.get(edge.from);
  if(neighbors)neighbors.push(edge.to);else adjacency.set(edge.from,[edge.to]);
 }
 const queue=[start],distances=new Map([[start,0]]);
 for(let i=0;i<queue.length;i++){
  const cell=queue[i];
  for(const next of adjacency.get(cell)||[]){
   if(distances.has(next))continue;
   distances.set(next,distances.get(cell)!+1);queue.push(next);
  }
 }
 const rooms=new Map<string,number>();
 // Keep the existing first-cell-per-room target and unreachable sentinel.
 for(const cell of navigation?.cells||[]){
  if(!rooms.has(cell.room_id))rooms.set(cell.room_id,distances.get(cell.id)||999999);
 }
 return rooms;
}
