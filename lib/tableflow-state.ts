import {z} from 'zod';
import type {Store} from './tableflow';
const text=z.string(),num=z.number().finite().nonnegative(),table=z.number().int().min(1).max(12);
const line=z.object({dishId:text,name:text,price:num,qty:z.number().int().min(1).max(20),note:text.max(200)});
const schema=z.object({dishes:z.array(z.object({id:text,name:text,desc:text,price:num,category:text,veg:z.boolean(),image:text,tag:text.optional(),available:z.boolean(),time:num})),orders:z.array(z.object({id:text,session:text,table,items:z.array(line),status:z.enum(['Placed','Preparing','Ready','Served']),created:num})),visits:z.array(z.object({id:text,table,open:z.boolean(),created:num})),requests:z.array(z.object({id:text,session:text,table,type:text,done:z.boolean()})),restaurants:z.array(z.object({id:text,name:text,location:text,plan:text,active:z.boolean(),modules:z.array(text)})),staff:z.array(z.object({id:text,name:text,email:text,role:text})),settings:z.object({name:text,wait:z.number().min(1).max(120),tax:z.number().min(0).max(30)}),cart:z.array(line),session:text,table});
export function parseStore(raw:string):Store{return schema.parse(JSON.parse(raw));}
export function placeOrder(d:Store,id:string,created:number):Store{
 if(!d.cart.length)return d;
 if(!d.visits.some(v=>v.id===d.session&&v.table===d.table&&v.open))throw Error('This visit has ended. Start a new visit first.');
 const items=d.cart.map(l=>{const dish=d.dishes.find(x=>x.id===l.dishId);if(!dish?.available)throw Error('An item is no longer available. Please remove it from your bag.');if(dish.price!==l.price)throw Error('A price has changed. Remove and re-add the item to review its current price.');return {...l,name:dish.name};});
 return {...d,orders:[{id,created,session:d.session,table:d.table,items,status:'Placed'},...d.orders],cart:[]};
}
export function route(raw:string){const p=raw.replace(/^#/,'').replace(/\/$/,'')||'/';if(['/','/cart','/orders','/bill','/service'].includes(p)||['overview','orders','kitchen','menu','tables','analytics','staff','settings'].some(s=>p===`/restaurant/${s}`)||['overview','restaurants','subscriptions','modules','revenue','users','settings'].some(s=>p===`/super-admin/${s}`))return p;if(p==='/restaurant')return '/restaurant/overview';if(p==='/super-admin')return '/super-admin/overview';return '/';}
