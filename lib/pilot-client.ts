export type Config={url:string;publishableKey:string;configured:boolean;version?:number;keyPresent?:boolean;databaseReady?:boolean;setupMessage?:string};
export type Dish={id:string;name:string;description:string;price:number;category:string;veg:boolean;image:string;available:boolean};
export type Item={id:string;name:string;price:number;qty:number;note:string};
export type Ticket={id:string;status:'Placed'|'Preparing'|'Ready'|'Served';created:string;items:Item[]};
export type Visit={id:string;table:number;closed:string|null;tax:number;orders:Ticket[]};
export type Menu={name:string;restaurant:string;table:number;wait:number;signal:string;dishes:Dish[]};
export type StaffView={name:string;role:'manager'|'kitchen'|'waiter';signal:string;tables:{id:string;number:number;enabled?:boolean;qr:string;visit:{id:string;code:string|null}|null}[];visits:Visit[]};
export type Pending={id:string;items:Item[]};
export class RpcError extends Error{constructor(message:string,public uncertain=false){super(message)}}
export async function rpc<T>(config:Config,name:string,args:Record<string,unknown>,fetcher:typeof fetch=fetch):Promise<T>{
 if(!config.configured)throw new RpcError('The pilot is not connected yet.');
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),15000);
 try{
  const response=await fetcher(`${config.url}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:config.publishableKey,'Content-Type':'application/json'},body:JSON.stringify(args),signal:controller.signal,cache:'no-store'});
  const raw=await response.text();
  let body:unknown=null;
  if(raw.trim())try{body=JSON.parse(raw)}catch{
   throw new RpcError(response.ok?'The server returned an unreadable response. Refresh to check whether the change was saved.':`The server could not complete the request (HTTP ${response.status}). Please try again.`,response.ok||response.status>=500);
  }
  // PostgreSQL void RPCs can succeed with an empty response body.
  const emptySuccess=['tfp_logout','tfp_admin_logout','tfp_admin_manage','tfp_resolve_review','tfp_status','tfp_close','tfp_settle'].includes(name);
  if(response.ok&&body===null&&!emptySuccess)throw new RpcError('The server returned no confirmation. Refresh to check the result before retrying.',true);
  const detail=body&&typeof body==='object'?body as Record<string,unknown>:{};
  if(!response.ok)throw new RpcError(response.status===404?'Pilot database setup is not complete.':typeof detail.message==='string'?detail.message:'The server could not complete the request.',response.status>=500);
  if(typeof detail.error==='string')throw new RpcError(detail.error);
  return body as T;
 }catch(error){if(error instanceof RpcError)throw error;const description=name==='tfp_order'?'Connection interrupted. Your order is not confirmed. Reconnect and retry the same order.':name==='tfp_login'||name==='tfp_staff_login'||name==='tfp_admin_login'?'Could not reach the sign-in service. Check your connection and try signing in again.':'Connection interrupted. The action could not be confirmed. Refresh to check its result before retrying.';throw new RpcError(description,true)}finally{clearTimeout(timeout)}
}
export function guestToken(){return crypto.randomUUID().replaceAll('-','')+crypto.randomUUID().replaceAll('-','')}
export function sum(items:Item[]){return Math.round(items.reduce((s,i)=>s+Math.round(i.price*100)*i.qty,0))/100}
export function bill(visit:Visit){const subtotal=sum(visit.orders.flatMap(o=>o.items));const tax=Math.round(subtotal*visit.tax)/100;return {subtotal,tax,total:Math.round((subtotal+tax)*100)/100}}
export function stage(items:Item[],dish:Dish,delta:number){const existing=items.find(i=>i.id===dish.id);const qty=(existing?.qty||0)+delta;if(!Number.isInteger(delta)||!Number.isInteger(qty))throw Error('Choose a whole quantity.');if(!existing&&items.length>=30&&delta>0)throw Error('Maximum 30 different dishes per order.');if(qty>20)throw Error('Maximum 20 of each dish per order.');if(delta>0&&!dish.available)throw Error('This dish is unavailable.');if(qty<=0)return items.filter(i=>i.id!==dish.id);return existing?items.map(i=>i.id===dish.id?{...i,qty,price:delta>0?dish.price:i.price}:i):[...items,{id:dish.id,name:dish.name,price:dish.price,qty,note:''}];}
export function readDraft(raw:string|null):{cart:Item[];pending:Pending|null}{if(!raw)return {cart:[],pending:null};const d=JSON.parse(raw);const valid=(a:unknown):a is Item[]=>Array.isArray(a)&&a.length<=30&&a.every(i=>i&&typeof i.id==='string'&&typeof i.name==='string'&&Number.isFinite(i.price)&&i.price>0&&Number.isInteger(i.qty)&&i.qty>0&&i.qty<=20&&typeof i.note==='string'&&i.note.length<=200);if(!valid(d.cart)||(d.pending&&(!/^[a-f0-9-]{36}$/.test(d.pending.id)||!valid(d.pending.items))))throw Error('The saved bag could not be read.');return {cart:d.cart,pending:d.pending||null};}
