-- Apply after 002_live_pilot.sql. Preserves existing restaurants, visits and orders.
-- Fees are agreed charges, not proof of payment and not an online payment gateway.
begin;
create table if not exists tableflow_pilot.platform_admins(
 id uuid primary key default gen_random_uuid(), username text unique not null,
 password_hash text not null, active boolean not null default true,
 failures integer not null default 0, locked_until timestamptz
);
create table if not exists tableflow_pilot.admin_sessions(
 token_hash bytea primary key, admin uuid not null references tableflow_pilot.platform_admins(id),
 expires timestamptz not null default now()+interval '1 hour'
);
create table if not exists tableflow_pilot.restaurant_contracts(
 restaurant uuid primary key references tableflow_pilot.restaurants(id),
 request_id uuid unique not null, created_by uuid not null references tableflow_pilot.platform_admins(id),
 owner_name text not null, contact text not null default '',
 billing text not null check(billing in ('monthly','one_time','both','free')),
 monthly_amount numeric(12,2) not null check(monthly_amount between 0 and 10000000),
 setup_amount numeric(12,2) not null check(setup_amount between 0 and 10000000),
 currency text not null default 'INR' check(currency='INR'),
 created_at timestamptz not null default now()
);
alter table tableflow_pilot.tables drop constraint if exists tables_number_check;
alter table tableflow_pilot.tables add constraint tables_number_check check(number between 1 and 100);
alter table tableflow_pilot.visits add column if not exists settled_total numeric(12,2);
revoke all on all tables in schema tableflow_pilot from public,anon,authenticated;

create or replace function tableflow_pilot.admin_actor(p_token text) returns uuid
language plpgsql set search_path=pg_catalog,tableflow_pilot as $$declare a uuid;begin
 select s.admin into a from tableflow_pilot.admin_sessions s join tableflow_pilot.platform_admins p on p.id=s.admin
 where s.token_hash=tableflow_pilot.hash(p_token) and s.expires>now() and p.active;
 if a is null then raise exception 'Please sign in as platform admin' using errcode='42501';end if;return a;
end$$;
create or replace function public.tfp_admin_login(p_username text,p_password text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare a tableflow_pilot.platform_admins;t text;begin
 select * into a from tableflow_pilot.platform_admins where username=lower(trim(p_username)) and active for update;
 if a.id is null then return jsonb_build_object('error','Username or password is incorrect');end if;
 if a.locked_until>now() then return jsonb_build_object('error','Too many attempts. Try again in five minutes.');end if;
 if p_password is null or octet_length(p_password)>72 or tableflow_pilot.pin_hash(p_password,a.password_hash)<>a.password_hash then
 update tableflow_pilot.platform_admins set failures=case when failures>=4 then 0 else failures+1 end,
 locked_until=case when failures>=4 then now()+interval '5 minutes' else null end where id=a.id;
 return jsonb_build_object('error','Username or password is incorrect');end if;
 update tableflow_pilot.platform_admins set failures=0,locked_until=null where id=a.id;
 delete from tableflow_pilot.admin_sessions where expires<now();t=tableflow_pilot.token();
 insert into tableflow_pilot.admin_sessions(token_hash,admin) values(tableflow_pilot.hash(t),a.id);
 return jsonb_build_object('token',t,'role','admin','username',a.username);end$$;
create or replace function public.tfp_admin_logout(p_token text) returns void
language sql security definer set search_path=pg_catalog,tableflow_pilot as $$delete from tableflow_pilot.admin_sessions where token_hash=tableflow_pilot.hash(p_token)$$;

-- Existing numeric PINs continue working; newly created owners receive strong passwords.
create or replace function public.tfp_login(p_slug text,p_username text,p_pin text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;t text;begin
 select a.* into s from tableflow_pilot.staff a join tableflow_pilot.restaurants r on r.id=a.restaurant
 where r.slug=lower(trim(p_slug)) and r.active and a.username=trim(p_username) and a.active for update of a;
 if s.id is null then return jsonb_build_object('error','Restaurant code, username or password is incorrect');end if;
 if s.locked_until>now() then return jsonb_build_object('error','Too many attempts. Try again in five minutes.');end if;
 if p_pin is null or octet_length(p_pin)>72 or tableflow_pilot.pin_hash(p_pin,s.pin_hash)<>s.pin_hash then
 update tableflow_pilot.staff set failures=case when failures>=4 then 0 else failures+1 end,
 locked_until=case when failures>=4 then now()+interval '5 minutes' else null end where id=s.id;
 return jsonb_build_object('error','Restaurant code, username or password is incorrect');end if;
 update tableflow_pilot.staff set failures=0,locked_until=null where id=s.id;
 delete from tableflow_pilot.staff_sessions where expires<now();t=tableflow_pilot.token();
 insert into tableflow_pilot.staff_sessions(token_hash,staff) values(tableflow_pilot.hash(t),s.id);
 return jsonb_build_object('token',t,'role',s.role,'username',s.username);end$$;

create or replace function public.tfp_admin_restaurants(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$begin
 perform tableflow_pilot.admin_actor(p_token);
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'slug',r.slug,'active',r.active,
 'tables',(select count(*) from tableflow_pilot.tables t where t.restaurant=r.id),'owner',c.owner_name,
 'contact',c.contact,'billing',c.billing,'monthly_amount',c.monthly_amount,'setup_amount',c.setup_amount,'currency','INR') order by r.name)
 from tableflow_pilot.restaurants r left join tableflow_pilot.restaurant_contracts c on c.restaurant=r.id),'[]'::jsonb);
end$$;

create or replace function public.tfp_admin_create_restaurant(p_token text,p_request uuid,p_details jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$
declare a uuid;r uuid;sig uuid;existing tableflow_pilot.restaurant_contracts;
 n text=trim(p_details->>'name');v_slug text=lower(trim(p_details->>'slug'));u text=trim(p_details->>'username');
 pw text=p_details->>'password';owner text=trim(p_details->>'owner');contact text=trim(coalesce(p_details->>'contact',''));
 mode text=p_details->>'billing';monthly numeric;setup numeric;tax numeric;tables integer;
begin
 a=tableflow_pilot.admin_actor(p_token);
 if p_request is null then raise exception 'Missing creation request';end if;
 -- Serialize retries of this request before checking the unique request identifier.
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into existing from tableflow_pilot.restaurant_contracts where request_id=p_request;
 if existing.restaurant is not null then
 if existing.created_by<>a then raise exception 'Request unavailable';end if;
 return jsonb_build_object('id',existing.restaurant,'slug',(select x.slug from tableflow_pilot.restaurants x where x.id=existing.restaurant));end if;
 if n is null or length(n) not between 2 and 100 or v_slug is null or v_slug!~'^[a-z0-9][a-z0-9-]{2,39}$'
 or u is null or u!~'^[A-Za-z0-9_.-]{3,40}$' or owner is null or length(owner) not between 2 and 100 or length(contact)>120
 then raise exception 'Check restaurant name, code, owner and username';end if;
 if pw is null or length(pw)<12 or octet_length(pw)>72 or pw!~'[A-Za-z]' or pw!~'[0-9]'
 then raise exception 'Use a password with 12 or more characters, letters and numbers (maximum 72 bytes)';end if;
 if mode is null or mode not in ('monthly','one_time','both','free') then raise exception 'Choose a billing arrangement';end if;
 if coalesce(p_details->>'monthly_amount','')!~'^[0-9]{1,8}(\.[0-9]{1,2})?$' or coalesce(p_details->>'setup_amount','')!~'^[0-9]{1,8}(\.[0-9]{1,2})?$'
 or coalesce(p_details->>'tax','')!~'^[0-9]{1,2}(\.[0-9]{1,2})?$' or coalesce(p_details->>'tables','')!~'^[0-9]{1,3}$' then raise exception 'Enter valid amounts, tax and table count';end if;
 monthly=(p_details->>'monthly_amount')::numeric;setup=(p_details->>'setup_amount')::numeric;
 tax=(p_details->>'tax')::numeric;tables=(p_details->>'tables')::integer;
 if monthly>10000000 or setup>10000000 or tax>30 or tables not between 1 and 100 then raise exception 'Amounts, tax or table count are outside the allowed range';end if;
 if (mode in ('monthly','both') and monthly<=0) or (mode in ('one_time','both') and setup<=0)
 or (mode in ('one_time','free') and monthly<>0) or (mode in ('monthly','free') and setup<>0)
 then raise exception 'The amounts must match the selected billing arrangement';end if;
 if exists(select 1 from tableflow_pilot.restaurants x where x.slug=v_slug) then raise exception 'Restaurant code already exists. Choose another code.';end if;
 insert into public.tfp_signals default values returning id into sig;
 insert into tableflow_pilot.restaurants(name,slug,tax,signal) values(n,v_slug,tax,sig) returning id into r;
 insert into tableflow_pilot.staff(restaurant,username,pin_hash,role) values(r,u,tableflow_pilot.pin_hash(pw),'manager');
 insert into tableflow_pilot.tables(restaurant,number) select r,generate_series(1,tables);
 insert into tableflow_pilot.restaurant_contracts(restaurant,request_id,created_by,owner_name,contact,billing,monthly_amount,setup_amount)
 values(r,p_request,a,owner,contact,mode,monthly,setup);
 return jsonb_build_object('id',r,'slug',v_slug);
end$$;

create or replace function public.tfp_owner_settings(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 s=tableflow_pilot.actor(p_token,array['manager']);
 return jsonb_build_object('contract',(select jsonb_build_object('billing',c.billing,'monthly_amount',c.monthly_amount,'setup_amount',c.setup_amount,'currency',c.currency,'owner',c.owner_name) from tableflow_pilot.restaurant_contracts c where c.restaurant=s.restaurant),
 'menu',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'description',m.description,'price',m.price,'category',m.category,'veg',m.veg,'available',m.available,'image',m.image) order by m.category,m.name) from tableflow_pilot.menu m where m.restaurant=s.restaurant),'[]'::jsonb));
end$$;
create or replace function public.tfp_owner_save_dish(p_token text,p_id uuid,p_dish jsonb) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;existing tableflow_pilot.menu;begin
 s=tableflow_pilot.actor(p_token,array['manager']);
 if p_id is null or coalesce(length(trim(p_dish->>'name')),0) not between 1 and 100
 or coalesce(length(trim(p_dish->>'category')),0) not between 1 and 50 or length(coalesce(p_dish->>'description',''))>500
 or coalesce(p_dish->>'price','')!~'^[0-9]{1,6}(\.[0-9]{1,2})?$' or (p_dish->>'price')::numeric<=0
 or coalesce(p_dish->>'veg','') not in ('true','false') or coalesce(p_dish->>'available','') not in ('true','false') then raise exception 'Check the dish name, category, price and availability';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
 select * into existing from tableflow_pilot.menu where id=p_id for update;
 if existing.id is not null and existing.restaurant<>s.restaurant then raise exception 'Dish unavailable' using errcode='42501';end if;
 insert into tableflow_pilot.menu(id,restaurant,name,description,price,category,veg,available)
 values(p_id,s.restaurant,trim(p_dish->>'name'),coalesce(p_dish->>'description',''),(p_dish->>'price')::numeric,trim(p_dish->>'category'),(p_dish->>'veg')::boolean,(p_dish->>'available')::boolean)
 on conflict(id) do update set name=excluded.name,description=excluded.description,price=excluded.price,category=excluded.category,veg=excluded.veg,available=excluded.available;
 perform tableflow_pilot.ping(s.restaurant);return p_id;
end$$;

create or replace function public.tfp_order(p_token text,p_request uuid,p_items jsonb) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v tableflow_pilot.visits;t tableflow_pilot.tables;m tableflow_pilot.menu;i jsonb;items jsonb='[]';h bytea;o tableflow_pilot.orders;begin
 h=tableflow_pilot.hash(p_token);select x.* into v from tableflow_pilot.visits x join tableflow_pilot.guests g on g.visit=x.id where g.token_hash=h for update of x;
 if v.id is null then raise exception 'Please join your table visit';end if;
 -- Return confirmed retries even if staff closed the visit after accepting the order.
 select * into o from tableflow_pilot.orders where guest_hash=h and request_id=p_request;if o.id is not null then return o.id;end if;
 if v.closed is not null then raise exception 'Your visit has ended';end if;
 if (select count(*) from tableflow_pilot.orders where visit=v.id)>=100 then raise exception 'This visit has reached its order limit. Ask staff for help.';end if;
 if exists(select 1 from tableflow_pilot.orders where guest_hash=h and created>clock_timestamp()-interval '2 seconds') then raise exception 'Please wait two seconds before sending another order';end if;
 select * into t from tableflow_pilot.tables where id=v.table_id;
 if not exists(select 1 from tableflow_pilot.restaurants where id=t.restaurant and active) then raise exception 'Restaurant unavailable';end if;
 if p_request is null or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'Invalid order';end if;
 if (select count(distinct j->>'id') from jsonb_array_elements(p_items) j)<>jsonb_array_length(p_items) then raise exception 'Each dish must appear only once per order';end if;
 for i in select * from jsonb_array_elements(p_items) loop
 if (i->>'qty') is null or (i->>'qty')!~'^[0-9]{1,2}$' or (i->>'qty')::integer not between 1 and 20 or length(coalesce(i->>'note',''))>200 then raise exception 'Invalid item quantity or note';end if;
 select * into m from tableflow_pilot.menu where id=(i->>'id')::uuid and restaurant=t.restaurant and available for share;
 if m.id is null then raise exception 'A dish is unavailable. Review your bag.';end if;
 if (i->>'price') is null or (i->>'price')::numeric<>m.price then raise exception 'A price changed. Review your bag.';end if;
 items=items||jsonb_build_array(jsonb_build_object('id',m.id,'name',m.name,'price',m.price,'qty',(i->>'qty')::integer,'note',coalesce(i->>'note','')));
 end loop;
 insert into tableflow_pilot.orders(visit,guest_hash,request_id,items) values(v.id,h,p_request,items) returning id into o.id;perform tableflow_pilot.ping(t.restaurant);return o.id;end$$;

revoke all on all functions in schema tableflow_pilot from public,anon,authenticated;
revoke all on function public.tfp_admin_login(text,text),public.tfp_admin_logout(text),public.tfp_admin_restaurants(text),public.tfp_admin_create_restaurant(text,uuid,jsonb),public.tfp_owner_settings(text),public.tfp_owner_save_dish(text,uuid,jsonb) from public;
grant execute on function public.tfp_admin_login(text,text),public.tfp_admin_logout(text),public.tfp_admin_restaurants(text),public.tfp_admin_create_restaurant(text,uuid,jsonb),public.tfp_owner_settings(text),public.tfp_owner_save_dish(text,uuid,jsonb) to anon,authenticated;
create or replace function public.tfp_settle(p_token text,p_visit uuid,p_total numeric) returns void
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;v tableflow_pilot.visits;subtotal numeric;total numeric;begin
 s=tableflow_pilot.actor(p_token,array['manager']);
 select x.* into v from tableflow_pilot.visits x join tableflow_pilot.tables t on t.id=x.table_id where x.id=p_visit and t.restaurant=s.restaurant for update of x;
 if v.id is null then raise exception 'Visit unavailable';end if;
 if exists(select 1 from tableflow_pilot.orders where visit=v.id and status<>'Served') then raise exception 'Serve all orders before settling this visit';end if;
 select coalesce(sum((i->>'price')::numeric*(i->>'qty')::integer),0) into subtotal from tableflow_pilot.orders o cross join lateral jsonb_array_elements(o.items) i where o.visit=v.id;
 total=subtotal+round(subtotal*v.tax/100,2);
 if p_total is distinct from total then raise exception 'The bill changed. Refresh and confirm the current total before settling.';end if;
 update tableflow_pilot.visits set closed=coalesce(closed,now()),settled_total=total where id=v.id;perform tableflow_pilot.ping(s.restaurant);
end$$;
revoke all on function public.tfp_settle(text,uuid,numeric) from public;
grant execute on function public.tfp_settle(text,uuid,numeric) to anon,authenticated;
create or replace function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',2)$$;
commit;
