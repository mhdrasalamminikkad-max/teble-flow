import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
const db=new PGlite({extensions:{pgcrypto}});await db.exec('create role anon; create role authenticated;');
for(const f of ['002_live_pilot.sql','004_restaurant_admin.sql','006_operations.sql','007_exclusive_qr.sql','008_owner_access_billing.sql','009_restaurant_roles.sql'])await db.exec(readFileSync(new URL('../supabase/'+f,import.meta.url),'utf8'));
const sql=async(q,args=[]) => (await db.query(q,args)).rows;
const call=async(name,args=[]) => (await sql(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
for(const slug of ['first','second'])await sql('select tableflow_pilot.provision($1,$1,$2,$3)',[slug,'shared','83726194']);
await db.exec(readFileSync(new URL('../supabase/010_username_login.sql',import.meta.url),'utf8'));
test('ambiguous legacy usernames never authenticate to an arbitrary restaurant',async()=>{
 assert.match((await call('tfp_staff_login',['shared','83726194'])).error,/multiple accounts/);
});
test('new username collisions are rejected, including case variants',async()=>{
 await assert.rejects(()=>sql("select tableflow_pilot.provision('Third','third','SHARED','83726194')"),/already taken/);
 await sql("update tableflow_pilot.staff set username='firstowner' where restaurant=(select id from tableflow_pilot.restaurants where slug='first')");
 await assert.rejects(()=>sql("update tableflow_pilot.staff set username='FIRSTOWNER' where username='shared'"),/already taken/);
});
test('username/password alone selects the correct restaurant and remembers the session',async()=>{
 const {token}=await call('tfp_staff_login',['FirstOwner','83726194']);assert.ok(token);
 assert.equal((await call('tfp_workspace',[token])).name,'first');
 assert.equal((await sql('select expires::text as expiry from tableflow_pilot.staff_sessions where token_hash=tableflow_pilot.hash($1)',[token]))[0].expiry,'infinity');
 await call('tfp_logout',[token]);await assert.rejects(()=>call('tfp_workspace',[token]),/sign in/);
});
test('incorrect passwords and inactive accounts remain denied',async()=>{
 assert.ok((await call('tfp_staff_login',['firstowner','wrong'])).error);
 await sql("update tableflow_pilot.staff set active=false where username='firstowner'");
 assert.ok((await call('tfp_staff_login',['firstowner','83726194'])).error);
 assert.equal((await call('tfp_health')).version,7);
});
after(()=>db.close());
