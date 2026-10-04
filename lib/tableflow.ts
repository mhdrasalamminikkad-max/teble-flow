export type Dish={id:string;name:string;desc:string;price:number;category:string;veg:boolean;image:string;tag?:string;available:boolean;time:number};
export type Line={dishId:string;name:string;price:number;qty:number;note:string};
export type Order={id:string;session:string;table:number;items:Line[];status:'Placed'|'Preparing'|'Ready'|'Served';created:number};
export type Visit={id:string;table:number;open:boolean;created:number};
export type Restaurant={id:string;name:string;location:string;plan:string;active:boolean;modules:string[]};
export type Store={dishes:Dish[];orders:Order[];visits:Visit[];requests:{id:string;session:string;table:number;type:string;done:boolean}[];restaurants:Restaurant[];staff:{id:string;name:string;email:string;role:string}[];settings:{name:string;wait:number;tax:number};cart:Line[];session:string;table:number};
export const menu:Dish[]=[
{id:'biryani',name:'Malabar chicken biryani',desc:'Fragrant kaima rice, slow-cooked chicken, caramelised onions & our house raita.',price:249,category:'Biryani',veg:false,image:'/food/biryani.jpg',tag:'CHEF’S FAVOURITE',available:true,time:20},
{id:'grill',name:'Smoky grilled chicken',desc:'Flame-kissed chicken with warm spices, fresh salad & garlic dip.',price:329,category:'Grills',veg:false,image:'/food/grill.jpg',tag:'BESTSELLER',available:true,time:25},
{id:'lime',name:'Fresh mint lime',desc:'Fresh lime, muddled mint and a little sparkle. Made to refresh.',price:89,category:'Drinks',veg:true,image:'/food/lime.jpg',available:true,time:5},
{id:'veg',name:'Garden vegetable biryani',desc:'Seasonal vegetables layered with fragrant rice, herbs & gentle spices.',price:199,category:'Biryani',veg:true,image:'',available:true,time:18},
{id:'paneer',name:'Chargrilled paneer tikka',desc:'Soft paneer, yoghurt marinade, peppers & a bright mint chutney.',price:229,category:'Grills',veg:true,image:'',available:true,time:20},
{id:'dessert',name:'Tender coconut pudding',desc:'A silky coconut finish, lightly sweet and served chilled.',price:119,category:'Desserts',veg:true,image:'',tag:'SWEET FINISH',available:true,time:5}
];
export function initial():Store{return {dishes:menu.map(d=>({...d})),orders:[],visits:[],requests:[],restaurants:[{id:'malabar',name:'Malabar House',location:'Kozhikode, Kerala',plan:'Growth',active:true,modules:['QR ordering','Kitchen display','Analytics']},{id:'pepper',name:'Pepper & Co.',location:'Kochi, Kerala',plan:'Starter',active:true,modules:['QR ordering']},{id:'cafe',name:'The Green Café',location:'Malappuram, Kerala',plan:'Growth',active:false,modules:['QR ordering','Analytics']}],staff:[{id:'1',name:'Restaurant manager',email:'manager@example.com',role:'Manager'},{id:'2',name:'Kitchen team',email:'chef@example.com',role:'Kitchen'}],settings:{name:'Malabar House',wait:20,tax:5},cart:[],session:'',table:7}}
const currency=new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR',maximumFractionDigits:2});
export const money=(n:number)=>currency.format(n);
export const total=(items:Line[])=>items.reduce((s,i)=>s+i.qty*i.price,0);
export const uid=()=>{const bytes=crypto.getRandomValues(new Uint8Array(16));bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;const h=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`};
