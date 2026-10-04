import {test} from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {readFileSync} from 'node:fs';
const code=ts.transpileModule(readFileSync(new URL('../lib/pos-lock.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {createLogin,verifyLogin,parseLogin}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
test('PIN is salted and only correct local credentials unlock',async()=>{const a=await createLogin('cashier','183629'),b=await createLogin('cashier','183629');assert.notEqual(a.hash,b.hash);assert.equal(await verifyLogin(a,'cashier','183629'),true);assert.equal(await verifyLogin(a,'cashier','183628'),false);assert.equal(await verifyLogin(a,'other','183629'),false);assert.equal(JSON.stringify(a).includes('183629'),false);assert.deepEqual(parseLogin(JSON.stringify(a)),a)});
test('invalid local login setup and corrupt saved records fail',async()=>{await assert.rejects(()=>createLogin('','183629'));await assert.rejects(()=>createLogin('cashier','123'));await assert.rejects(()=>createLogin('cashier','abcdef'));assert.throws(()=>parseLogin('{}'));assert.throws(()=>parseLogin('null'))});
