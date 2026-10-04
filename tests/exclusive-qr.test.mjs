import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
const db=new PGlite({extensions:{pgcrypto}});
await db.exec('create role anon; create role authenticated;');
for(const file of ['002_live_pilot.sql','004_restaurant_admin.sql','006_operations.sql','007_exclusive_qr.sql'])await db.exec(readFileSync(new URL('../supabase/'+file,import.meta.url),'utf8'));
const sql=async(q,args=[]) => (await db.query(q,args)).rows;
const call=async(name,args=[]) => (await sql(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
const [{id}]=await sql("select tableflow_pilot.provision('QR test','qr-test','owner','83726194') as id");
const {token}=await call('tfp_login',['qr-test','owner','83726194']);
const table=(await call('tfp_staff',[token])).tables[0];
const table2=(await call('tfp_staff',[token])).tables[1];
const [{id:dish}]=await sql("insert into tableflow_pilot.menu(restaurant,name,price,category) values($1,'Meal',100,'Meals') returning id",[id]);
const first='a'.repeat(64),second='b'.repeat(64),third='c'.repeat(64);
let visit,order;
const items=JSON.stringify([{id:dish,qty:1,price:100,note:''}]);
test('QR claim needs an open enabled table and a valid token',async()=>{
 await assert.rejects(()=>call('tfp_claim_table',[table.qr,first]),/open your table/);
 await call('tfp_open',[token,table.id]);
 await assert.rejects(()=>call('tfp_claim_table',[table.qr,'bad']),/Invalid guest token/);
 visit=await call('tfp_claim_table',[table.qr,first]);assert.equal(visit.table,1);
 assert.equal((await call('tfp_claim_table',[table.qr,first])).id,visit.id);
 order=await call('tfp_order',[first,crypto.randomUUID(),items]);
});
test('second scan revokes the first device and preserves its order and bill',async()=>{
 const next=await call('tfp_claim_table',[table.qr,second]);assert.equal(next.id,visit.id);assert.equal(next.orders[0].id,order);
 await assert.rejects(()=>call('tfp_guest',[first]),/TABLE_SESSION_REPLACED/);
 await assert.rejects(()=>call('tfp_order',[first,crypto.randomUUID(),items]),/TABLE_SESSION_REPLACED/);
 await assert.rejects(()=>call('tfp_guest_review',[first,1,'Old device']),/TABLE_SESSION_REPLACED/);
 await assert.rejects(()=>call('tfp_claim_table',[table.qr,first]),/TABLE_SESSION_REPLACED/);
 assert.equal((await call('tfp_guest',[second])).orders.length,1);
});
test('old code endpoint cannot bypass exclusive access',async()=>{
 await assert.rejects(()=>call('tfp_join',[table.qr,'00000000',third]),/no longer used/);
 assert.equal((await call('tfp_guest',[second])).id,visit.id);
});
test('separate tables stay independent and tokens cannot switch tables',async()=>{
 await call('tfp_open',[token,table2.id]);
 const other=await call('tfp_claim_table',[table2.qr,third]);assert.notEqual(other.id,visit.id);
 await assert.rejects(()=>call('tfp_claim_table',[table.qr,third]),/TABLE_SESSION_REPLACED/);
 assert.equal((await call('tfp_guest',[second])).id,visit.id);
});
test('multiple claims leave one active guest, and refresh never takes control back',async()=>{
 const tokens=['d','e','f'].map(c=>c.repeat(64));
 await Promise.all(tokens.map(t=>call('tfp_claim_table',[table.qr,t])));
 const active=await sql('select count(*)::int as n from tableflow_pilot.guests where visit=$1 and not revoked',[visit.id]);assert.equal(active[0].n,1);
 const results=await Promise.allSettled(tokens.map(t=>call('tfp_guest',[t])));assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 assert.equal((await call('tfp_guest',[third])).table,2);
});
test('health advertises the new protocol and disabled tables reject scans',async()=>{
 assert.equal((await call('tfp_health')).version,4);
 const unused=(await call('tfp_staff',[token])).tables[2];
 await call('tfp_owner_table',[token,unused.number,false]);
 await assert.rejects(()=>call('tfp_claim_table',[unused.qr,'9'.repeat(64)]),/unavailable/);
});
after(()=>db.close());

