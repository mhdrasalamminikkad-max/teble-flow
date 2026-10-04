// A device-local privacy lock, not server authentication or a tenant boundary.
export type DeviceLogin={username:string;salt:string;hash:string};
export const loginKey='tableflow-device-login-v1';
export function validPin(pin:string){return /^\d{6,12}$/.test(pin);}
export async function pinHash(pin:string,salt:string){
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(pin),'PBKDF2',false,['deriveBits']);
 const bits=await crypto.subtle.deriveBits({name:'PBKDF2',salt:new TextEncoder().encode(salt),iterations:210000,hash:'SHA-256'},key,256);
 return Array.from(new Uint8Array(bits),b=>b.toString(16).padStart(2,'0')).join('');
}
export async function createLogin(username:string,pin:string):Promise<DeviceLogin>{
 username=username.trim();if(!username||username.length>40||!validPin(pin))throw Error('Enter a username and a 6–12 digit PIN.');
 const salt=Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
 return {username,salt,hash:await pinHash(pin,salt)};
}
export function parseLogin(raw:string):DeviceLogin{const d=JSON.parse(raw);if(typeof d.username!=='string'||!d.username.trim()||d.username.length>40||typeof d.salt!=='string'||!/^\w{32}$/.test(d.salt)||typeof d.hash!=='string'||!/^\w{64}$/.test(d.hash))throw Error('The device login could not be read.');return d;}
export async function verifyLogin(record:DeviceLogin,username:string,pin:string){return validPin(pin)&&username.trim()===record.username&&(await pinHash(pin,record.salt))===record.hash;}
