import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const root=process.env.PGLITE_MODULE_ROOT;
if(!root)throw Error('Set PGLITE_MODULE_ROOT');
const {PGlite}=await import(pathToFileURL(root+'/dist/index.js'));
const {pgcrypto}=await import(pathToFileURL(root+'/dist/contrib/pgcrypto.js'));
const db=new PGlite({extensions:{pgcrypto}});
await db.exec('create role anon; create role authenticated;');
for(const file of ['002_live_pilot.sql','004_restaurant_admin.sql'])try{await db.exec(readFileSync(new URL('../supabase/'+file,import.meta.url),'utf8'))}catch(e){console.error('Migration failed:',file,e.message,'position:',e.position);await db.close();process.exit(1)}
const sql=async(q,args=[])=> (await db.query(q,args)).rows;
const call=async(name,args)=> (await sql(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as value`,args))[0].value;
await sql("insert into tableflow_pilot.platform_admins(username,password_hash) values('admin',tableflow_pilot.pin_hash($1))",['TestAdmin973!']);
const {token:admin}=await call('tfp_admin_login',['admin','TestAdmin973!']);
const details=(slug)=>({name:'Restaurant '+slug,slug,owner:'Test Owner',contact:'',username:'owner',password:'OwnerTest874!secure',tables:'5',tax:'5',billing:'both',monthly_amount:'1200.50',setup_amount:'5000'});
let a,b,ownerA,ownerB;
test('only authenticated platform admin can provision restaurants',async()=>{
 await assert.rejects(()=>call('tfp_admin_create_restaurant',['786786',crypto.randomUUID(),JSON.stringify(details('denied'))]),/admin/);
 await assert.rejects(()=>call('tfp_admin_restaurants',['']),/admin/);
 assert.ok((await call('tfp_admin_login',['admin','786786'])).error);
});
test('creation is atomic and retries return the same restaurant',async()=>{
 const id=crypto.randomUUID();const input=JSON.stringify(details('alpha'));
 const results=await Promise.all(Array.from({length:4},()=>call('tfp_admin_create_restaurant',[admin,id,input])));
 assert.equal(new Set(results.map(x=>x.id)).size,1);a=results[0];
 b=await call('tfp_admin_create_restaurant',[admin,crypto.randomUUID(),JSON.stringify({...details('bravo'),billing:'free',monthly_amount:'0',setup_amount:'0'})]);
 ownerA=(await call('tfp_login',['alpha','owner','OwnerTest874!secure'])).token;
 ownerB=(await call('tfp_login',['bravo','owner','OwnerTest874!secure'])).token;
 const v=await call('tfp_staff',[ownerA]);assert.equal(v.tables.length,5);assert.equal(v.role,'manager');
 const settings=await call('tfp_owner_settings',[ownerA]);assert.equal(settings.menu.length,0);assert.equal(settings.contract.monthly_amount,1200.5);assert.equal(settings.contract.setup_amount,5000);
 await assert.rejects(()=>call('tfp_admin_restaurants',[ownerA]),/admin/);
 const hashes=await sql('select pin_hash from tableflow_pilot.staff');assert.ok(hashes.every(x=>x.pin_hash!=='OwnerTest874!secure'));
});
test('invalid billing, null input, duplicate codes and weak passwords roll back',async()=>{
 const before=(await call('tfp_admin_restaurants',[admin])).length;
 for(const patch of [{name:null},{slug:null},{owner:''},{password:'786786'},{billing:null},{billing:'free'},{monthly_amount:'-1'},{setup_amount:'NaN'},{tables:'101'},{tax:'31'},{slug:'alpha'},{monthly_amount:'1.005'}]){
  await assert.rejects(()=>call('tfp_admin_create_restaurant',[admin,crypto.randomUUID(),JSON.stringify({...details('invalid-'+crypto.randomUUID().slice(0,8)),...patch})]));
 }
 assert.equal((await call('tfp_admin_restaurants',[admin])).length,before);
});
test('owners cannot alter another restaurant menu or fees',async()=>{
 const dish=crypto.randomUUID(),payload={name:'Lunch',category:'Meals',description:'',price:'249.50',veg:true,available:true};
 await call('tfp_owner_save_dish',[ownerA,dish,JSON.stringify(payload)]);
 await assert.rejects(()=>call('tfp_owner_save_dish',[ownerB,dish,JSON.stringify({...payload,price:'1'})]),/unavailable/);
 await assert.rejects(()=>call('tfp_admin_create_restaurant',[ownerA,crypto.randomUUID(),JSON.stringify(details('forbidden'))]),/admin/);
 assert.equal((await call('tfp_owner_settings',[ownerB])).menu.length,0);
 await sql("insert into tableflow_pilot.staff(restaurant,username,pin_hash,role) values($1,'chef',tableflow_pilot.pin_hash('1234567890'),'kitchen')",[a.id]);
 const chef=(await call('tfp_login',['alpha','chef','1234567890'])).token;
 await assert.rejects(()=>call('tfp_owner_settings',[chef]),/authorized/);
 await assert.rejects(()=>call('tfp_owner_save_dish',[chef,dish,JSON.stringify(payload)]),/authorized/);
});
test('stale prices, duplicate lines and changed bills cannot silently pass',async()=>{
 const view=await call('tfp_staff',[ownerA]),t=view.tables[0];await call('tfp_open',[ownerA,t.id]);
 const v=(await call('tfp_staff',[ownerA])).tables[0].visit,guest='c'.repeat(64);await call('tfp_join',[t.qr,v.code,guest]);
 const dish=(await call('tfp_owner_settings',[ownerA])).menu[0];
 const item={id:dish.id,qty:2,price:249.50,note:''};
 await assert.rejects(()=>call('tfp_order',[guest,crypto.randomUUID(),JSON.stringify([item,item])]),/once/);
 await assert.rejects(()=>call('tfp_order',[guest,crypto.randomUUID(),JSON.stringify([{...item,price:249}])]),/price changed/);
 const request=crypto.randomUUID(),order=await call('tfp_order',[guest,request,JSON.stringify([item])]);
 await assert.rejects(()=>call('tfp_settle',[ownerA,v.id,523.95]),/Serve all/);
 for(const status of ['Preparing','Ready','Served'])await call('tfp_status',[ownerA,order,status]);
 await assert.rejects(()=>call('tfp_settle',[ownerA,v.id,1]),/bill changed/);
 await assert.rejects(()=>call('tfp_settle',[ownerB,v.id,523.95]),/unavailable/);
 await call('tfp_settle',[ownerA,v.id,523.95]);await call('tfp_settle',[ownerA,v.id,523.95]);
 assert.equal((await sql('select settled_total from tableflow_pilot.visits where id=$1',[v.id]))[0].settled_total,'523.95');
 assert.equal(await call('tfp_order',[guest,request,JSON.stringify([item])]),order);
});
test('new tables retain separate visits and expired admin sessions are rejected',async()=>{
 const t=(await call('tfp_staff',[ownerA])).tables[0];await call('tfp_open',[ownerA,t.id]);
 const v=(await call('tfp_staff',[ownerA])).visits.find(x=>!x.closed);assert.equal(v.orders.length,0);
 await sql("update tableflow_pilot.admin_sessions set expires=now()-interval '1 second'");
 await assert.rejects(()=>call('tfp_admin_restaurants',[admin]),/admin/);
});
test('anonymous role has no direct access to contracts, accounts or sessions',async()=>{
 await db.exec('set role anon');try{for(const name of ['restaurant_contracts','platform_admins','admin_sessions','staff'])await assert.rejects(()=>sql('select * from tableflow_pilot.'+name),/permission denied/);assert.equal((await call('tfp_health',[])).version,2)}finally{await db.exec('reset role')}
});
test('admin lockout persists across failed login requests',async()=>{
 for(let n=0;n<5;n++)assert.ok((await call('tfp_admin_login',['admin','wrong'])).error);
 assert.match((await call('tfp_admin_login',['admin','TestAdmin973!'])).error,/five minutes/);
});
after(()=>db.close());
