import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
const db=new PGlite({extensions:{pgcrypto}});await db.exec('create role anon; create role authenticated;');
for(const f of ['002_live_pilot.sql','004_restaurant_admin.sql','006_operations.sql','007_exclusive_qr.sql','008_owner_access_billing.sql','009_restaurant_roles.sql']){try{await db.exec(readFileSync(new URL('../supabase/'+f,import.meta.url),'utf8'))}catch(e){console.error(f,e.message,e.position,readFileSync(new URL("../supabase/"+f,import.meta.url),"utf8").slice(Number(e.position)-100,Number(e.position)+100));process.exit(1)}}
const sql=async(q,args=[]) => (await db.query(q,args)).rows;
const call=async(name,args=[]) => (await sql(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
await sql("insert into tableflow_pilot.platform_admins(username,password_hash) values('admin',tableflow_pilot.pin_hash('AdminTest123456'))");
const {token:platform}=await call('tfp_admin_login',['admin','AdminTest123456']);
const details={name:'Role test',slug:'roles-test',owner:'Owner',contact:'',username:'owner',password:'Abc123',tables:'3',tax:'5',billing:'both',monthly_amount:'1000',setup_amount:'2000'};
const {id:restaurant}=await call('tfp_admin_create_restaurant',[platform,crypto.randomUUID(),JSON.stringify(details)]);
const {token:owner}=await call('tfp_login',['roles-test','owner','Abc123']);
const {id:otherRestaurant}=await call('tfp_admin_create_restaurant',[platform,crypto.randomUUID(),JSON.stringify({...details,slug:'other-roles'})]);
const {token:otherOwner}=await call('tfp_login',['other-roles','owner','Abc123']);
const roles={},tokens={},staff={};
for(const name of ['kitchen','waiter','biller','menu','feedback']){roles[name]=crypto.randomUUID();staff[name]=crypto.randomUUID();await call('tfp_role_save',[owner,roles[name],name,[name]]);await call('tfp_team_save',[owner,staff[name],name,'Abc123',roles[name],true]);tokens[name]=(await call('tfp_login',['roles-test',name,'Abc123'])).token;}
let table,visit,order,guest='a'.repeat(64);
test('owner has all tools; staff only receives assigned permissions and scoped data',async()=>{
 assert.ok((await call('tfp_workspace',[owner])).permissions.includes('admin'));
 const k=await call('tfp_workspace',[tokens.kitchen]);assert.deepEqual(k.permissions,['kitchen']);assert.deepEqual(k.team,[]);assert.deepEqual(k.roles,[]);assert.deepEqual(k.requests,[]);assert.equal(k.format,null);
 await assert.rejects(()=>call('tfp_operations',[tokens.kitchen,false]),/authorized/);
 await assert.rejects(()=>call('tfp_role_save',[tokens.kitchen,crypto.randomUUID(),'Escalate',['admin']]),/permission/);
 await assert.rejects(()=>call('tfp_role_save',[owner,crypto.randomUUID(),'Escalate',['admin']]),/valid permission/);
 await assert.rejects(()=>call('tfp_team_save',[otherOwner,crypto.randomUUID(),'hacker','Abc123',roles.kitchen,true]),/belonging/);
});
test('six-character mixed passwords accepted; weak or symbol-only passwords rejected',async()=>{
 for(const pw of ['123456','abcdef','Ab123','Ab123!'])await assert.rejects(()=>call('tfp_team_save',[owner,crypto.randomUUID(),'invalid',pw,roles.kitchen,true]),/6 characters/);
 const rows=await sql("select expires::text as expiry from tableflow_pilot.staff_sessions where token_hash=tableflow_pilot.hash($1)",[tokens.kitchen]);assert.equal(rows[0].expiry,'infinity');
});
test('waiter opens tables, kitchen advances orders, biller cannot prepare food',async()=>{
 table=(await call('tfp_workspace',[tokens.waiter])).tables[0];
 await assert.rejects(()=>call('tfp_open',[tokens.kitchen,table.id]),/permission/);
 await call('tfp_open',[tokens.waiter,table.id]);visit=await call('tfp_claim_table',[table.qr,guest]);
 const [{id:dish}]=await sql("insert into tableflow_pilot.menu(restaurant,name,price,category) values($1,'Meal',100,'Meals') returning id",[restaurant]);
 order=await call('tfp_order',[guest,crypto.randomUUID(),JSON.stringify([{id:dish,qty:1,price:100,note:'No chilli'}])]);
 await assert.rejects(()=>call('tfp_status',[tokens.biller,order,'Preparing']),/Not permitted/);
 await assert.rejects(()=>call('tfp_status',[tokens.waiter,order,'Preparing']),/Not permitted/);
 await call('tfp_status',[tokens.kitchen,order,'Preparing']);await call('tfp_status',[tokens.kitchen,order,'Ready']);
 const k=await call('tfp_workspace',[tokens.kitchen]);assert.equal(k.visits[0].table,1);assert.equal(k.visits[0].orders[0].status,'Ready');
 await call('tfp_status',[tokens.waiter,order,'Served']);
});
test('guest requests deduplicate, appear to waiter, and enforce tenant and role boundaries',async()=>{
 const id=await call('tfp_service_request',[guest,'Water']);assert.equal(await call('tfp_service_request',[guest,'Water']),id);
 assert.equal((await call('tfp_workspace',[tokens.waiter])).requests[0].table,1);
 await assert.rejects(()=>call('tfp_service_done',[tokens.kitchen,id]),/permission/);
 await assert.rejects(()=>call('tfp_service_done',[otherOwner,id]),/unavailable/);
 await call('tfp_service_done',[tokens.waiter,id]);assert.equal((await call('tfp_workspace',[tokens.waiter])).requests.length,0);
});
test('bill format persists, settlement checks totals, and menu access excludes subscription contract',async()=>{
 await call('tfp_bill_format',[tokens.biller,JSON.stringify({header:'Our restaurant',footer:'Thank you',paper:'58mm',showTax:false})]);
 assert.equal((await call('tfp_workspace',[tokens.biller])).format.paper,'58mm');
 await assert.rejects(()=>call('tfp_settle',[tokens.kitchen,visit.id,105]),/permission/);
 await assert.rejects(()=>call('tfp_settle',[tokens.biller,visit.id,1]),/bill changed/);
 await call('tfp_settle',[tokens.biller,visit.id,105]);
 assert.ok((await call('tfp_workspace',[tokens.biller])).visits[0].closed);
 assert.equal((await call('tfp_owner_settings',[tokens.menu])).contract,null);
 await assert.rejects(()=>call('tfp_owner_settings',[tokens.kitchen]),/permission/);
});
test('changing permissions and logout revoke persistent sessions',async()=>{
 await call('tfp_role_save',[owner,roles.kitchen,'kitchen',['kitchen','dashboard']]);
 await assert.rejects(()=>call('tfp_workspace',[tokens.kitchen]),/sign in/);
 const {token:fresh}=await call('tfp_login',['roles-test','kitchen','Abc123']);assert.ok((await call('tfp_workspace',[fresh])).permissions.includes('dashboard'));
 await call('tfp_logout',[fresh]);await assert.rejects(()=>call('tfp_workspace',[fresh]),/sign in/);
 assert.equal((await call('tfp_health')).version,6);
});
after(()=>db.close());

