import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
const db=new PGlite({extensions:{pgcrypto}});
await db.exec('create role anon; create role authenticated;');
for(const f of ['002_live_pilot.sql','004_restaurant_admin.sql','006_operations.sql','007_exclusive_qr.sql','008_owner_access_billing.sql'])await db.exec(readFileSync(new URL('../supabase/'+f,import.meta.url),'utf8'));
const sql=async(q,args=[]) => (await db.query(q,args)).rows;
const call=async(name,args=[]) => (await sql(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
await sql("insert into tableflow_pilot.platform_admins(username,password_hash) values('admin',tableflow_pilot.pin_hash('AdminTest123456'))");
const {token:admin}=await call('tfp_admin_login',['admin','AdminTest123456']);
const details={name:'Billing Test',slug:'billing-test',owner:'Owner',contact:'',username:'owner',password:'OwnerTest123456',tables:'3',tax:'5',billing:'both',monthly_amount:'1000',setup_amount:'2000'};
const {id}=await call('tfp_admin_create_restaurant',[admin,crypto.randomUUID(),JSON.stringify(details)]);
const {token:ownerToken}=await call('tfp_login',['billing-test','owner','OwnerTest123456']);
const owner=(await call('tfp_admin_restaurants',[admin]))[0].owners[0];
test('only platform admin can change owner access',async()=>{
 await assert.rejects(()=>call('tfp_admin_owner_access',[ownerToken,id,owner.id,'newowner','NewOwner123456']),/platform admin/);
 await assert.rejects(()=>call('tfp_admin_owner_access',[admin,crypto.randomUUID(),owner.id,'newowner','NewOwner123456']),/unavailable/);
 await assert.rejects(()=>call('tfp_admin_owner_access',[admin,id,owner.id,'newowner','short']),/12 characters/);
});
test('username/password change invalidates sessions and never exposes password hashes',async()=>{
 await call('tfp_admin_owner_access',[admin,id,owner.id,'newowner','NewOwner123456']);
 await assert.rejects(()=>call('tfp_staff',[ownerToken]),/sign in/);
 assert.ok((await call('tfp_login',['billing-test','owner','OwnerTest123456'])).error);
 assert.ok((await call('tfp_login',['billing-test','newowner','NewOwner123456'])).token);
 const restaurants=await call('tfp_admin_restaurants',[admin]);assert.equal(restaurants[0].owners[0].username,'newowner');assert.ok(!JSON.stringify(restaurants).includes('pin_hash'));
 await call('tfp_admin_owner_access',[admin,id,owner.id,'renamed','']);
 assert.ok((await call('tfp_login',['billing-test','renamed','NewOwner123456'])).token);
});
test('pending invoices generate automatically and repeated refreshes do not duplicate',async()=>{
 const a=await call('tfp_operations',[admin,true]);assert.equal(a.invoices.length,2);assert.equal(a.invoices.reduce((n,i)=>n+i.amount,0),3000);
 await Promise.all(Array.from({length:4},()=>call('tfp_operations',[admin,true])));
 assert.equal((await call('tfp_operations',[admin,true])).invoices.length,2);
});
test('partial payment reduces pending without changing the agreed invoice',async()=>{
 const inv=(await call('tfp_operations',[admin,true])).invoices.find(i=>i.kind==='monthly');
 await call('tfp_admin_payment',[admin,crypto.randomUUID(),inv.id,250,'bank-test']);
 const next=(await call('tfp_operations',[admin,true])).invoices.find(i=>i.id===inv.id);assert.equal(next.amount,1000);assert.equal(next.paid,250);assert.equal(next.amount-next.paid,750);
});
test('catch-up generates missing months, never duplicates setup or charges free plans',async()=>{
 const [{billing_start:start}]=await sql('select billing_start::text from tableflow_pilot.restaurant_contracts where restaurant=$1',[id]);
 await sql("select tableflow_pilot.generate_pending_invoices(($1::date+interval '2 months')::date,$2)",[start,id]);
 assert.equal((await sql('select count(*)::int as n from tableflow_pilot.invoices where restaurant=$1',[id]))[0].n,4);
 const {id:free}=await call('tfp_admin_create_restaurant',[admin,crypto.randomUUID(),JSON.stringify({...details,slug:'free-plan',billing:'free',monthly_amount:'0',setup_amount:'0'})]);
 await call('tfp_operations',[admin,true]);assert.equal((await sql('select count(*)::int as n from tableflow_pilot.invoices where restaurant=$1',[free]))[0].n,0);
});
test('anonymous callers cannot invoke the private billing generator or read audit data',async()=>{
 await db.exec('set role anon');
 await assert.rejects(()=>sql('select tableflow_pilot.generate_pending_invoices(current_date,null)'),/permission denied/);
 await assert.rejects(()=>sql('select * from tableflow_pilot.owner_access_audit'),/permission denied/);
 await db.exec('reset role');assert.equal((await call('tfp_health')).version,5);
});
after(()=>db.close());
