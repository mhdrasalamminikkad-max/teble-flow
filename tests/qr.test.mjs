import {test} from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {readFileSync} from 'node:fs';
const code=ts.transpileModule(readFileSync(new URL('../lib/qr.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {tableDestination}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
test('scanner accepts only a valid table QR on this website',()=>{
 const origin='https://tableflow.example',qr=crypto.randomUUID();
 assert.equal(tableDestination(`${origin}/pilot?qr=${qr}&staff=1`,origin),`/pilot?qr=${qr}`);
 for(const raw of [`https://evil.example/pilot?qr=${qr}`,`${origin}/login`,`${origin}/pilot?qr=invalid`,'javascript:alert(1)',`${origin}/pilot?staff=1`,`https://user:password@tableflow.example/pilot?qr=${qr}`])assert.equal(tableDestination(raw,origin),null);
});
