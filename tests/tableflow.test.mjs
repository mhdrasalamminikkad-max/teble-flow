import {test} from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {readFileSync} from 'node:fs';
const load=async name=>import('data:text/javascript;base64,'+Buffer.from(ts.transpileModule(readFileSync(new URL(`../lib/${name}.ts`,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText.replace("from 'zod'",`from '${import.meta.resolve('zod')}'`)).toString('base64'));
const {initial}=await load('tableflow');
const {parseStore,placeOrder,route}=await load('tableflow-state');
function fixture(){const d=initial();d.session='visit';d.visits=[{id:'visit',table:7,open:true,created:1}];const dish=d.dishes[0];d.cart=[{dishId:dish.id,name:dish.name,price:dish.price,qty:2,note:''}];return d;}
test('repeat order submission does not duplicate tickets',()=>{const d=fixture(),ordered=placeOrder(d,'one',2);assert.equal(ordered.orders.length,1);assert.equal(ordered.cart.length,0);assert.equal(placeOrder(ordered,'two',3),ordered);assert.equal(d.orders.length,0)});
test('closed and mismatched visits reject orders',()=>{const d=fixture();d.visits[0].open=false;assert.throws(()=>placeOrder(d,'one',2),/ended/);d.visits[0].open=true;d.visits[0].table=8;assert.throws(()=>placeOrder(d,'one',2),/ended/)});
test('unavailable dishes and changed prices reject stale carts',()=>{const d=fixture();d.dishes[0].available=false;assert.throws(()=>placeOrder(d,'one',2),/available/);d.dishes[0].available=true;d.dishes[0].price++;assert.throws(()=>placeOrder(d,'one',2),/price/)});
test('saved data validates nested quantities and statuses',()=>{const d=fixture();assert.deepEqual(parseStore(JSON.stringify(d)),d);d.cart[0].qty=-1;assert.throws(()=>parseStore(JSON.stringify(d)));assert.throws(()=>parseStore('{}'));assert.throws(()=>parseStore('invalid'))});
test('hash and direct routes normalize with safe fallback',()=>{for(const p of ['/cart','/orders','/bill','/service','/restaurant/kitchen','/super-admin/modules'])assert.equal(route('#'+p),p);assert.equal(route('/missing'),'/');assert.equal(route('/restaurant'),'/restaurant/overview')});
test('fresh stores do not share mutable dishes',()=>{const a=initial();a.dishes[0].available=false;assert.equal(initial().dishes[0].available,true)});
