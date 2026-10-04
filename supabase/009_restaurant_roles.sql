-- Restaurant roles, service requests, bill layouts and persistent staff sessions. Apply after 008.
begin;
create table if not exists tableflow_pilot.team_roles(id uuid primary key,restaurant uuid not null references tableflow_pilot.restaurants(id),name text not null,permissions text[] not null,unique(restaurant,name));
alter table tableflow_pilot.staff add column if not exists team_role uuid references tableflow_pilot.team_roles(id);
alter table tableflow_pilot.staff drop constraint if exists staff_role_check;
alter table tableflow_pilot.staff add constraint staff_role_check check(role in ('manager','kitchen','waiter','custom'));
alter table tableflow_pilot.staff_sessions alter column expires set default 'infinity'::timestamptz;
update tableflow_pilot.staff_sessions set expires='infinity' where expires>now();
alter table tableflow_pilot.restaurants add column if not exists bill_format jsonb not null default '{"header":"","footer":"Thank you for dining with us.","paper":"80mm","showTax":true}';
create table if not exists tableflow_pilot.service_requests(id uuid primary key default gen_random_uuid(),visit uuid not null references tableflow_pilot.visits(id),kind text not null check(kind in ('Water','Call waiter','Cutlery','Help with bill')),created timestamptz not null default now(),done boolean not null default false);
create unique index if not exists tfp_one_pending_request on tableflow_pilot.service_requests(visit,kind) where not done;
revoke all on tableflow_pilot.team_roles,tableflow_pilot.service_requests from public,anon,authenticated;
create or replace function tableflow_pilot.staff_permissions(s tableflow_pilot.staff) returns text[] language sql stable set search_path=pg_catalog,tableflow_pilot as $$
 select case when s.role='manager' then array['dashboard','kitchen','waiter','biller','menu','feedback','admin'] when s.role='kitchen' then array['kitchen'] when s.role='waiter' then array['waiter'] else coalesce((select permissions from tableflow_pilot.team_roles where id=s.team_role and restaurant=s.restaurant),'{}'::text[]) end
$$;
create or replace function tableflow_pilot.authorize(p_token text,p_permission text default null) returns tableflow_pilot.staff language plpgsql set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 select a.* into s from tableflow_pilot.staff a join tableflow_pilot.staff_sessions b on b.staff=a.id join tableflow_pilot.restaurants r on r.id=a.restaurant where b.token_hash=tableflow_pilot.hash(p_token) and b.expires>now() and a.active and r.active;
 if s.id is null then raise exception 'Please sign in with an authorized staff account' using errcode='42501';end if;
 if p_permission is not null and not(p_permission=any(tableflow_pilot.staff_permissions(s))) then raise exception 'You do not have permission for this tool' using errcode='42501';end if;return s;
end$$;
create or replace function public.tfp_role_save(p_token text,p_id uuid,p_name text,p_permissions text[]) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 s=tableflow_pilot.authorize(p_token,'admin');
 if p_id is null or p_name is null or length(trim(p_name)) not between 2 and 50 or p_permissions is null or cardinality(p_permissions)<1 or not(p_permissions<@array['dashboard','kitchen','waiter','biller','menu','feedback']) then raise exception 'Choose a role name and at least one valid permission';end if;
 perform 1 from tableflow_pilot.restaurants where id=s.restaurant for update;
 if exists(select 1 from tableflow_pilot.team_roles where id=p_id and restaurant<>s.restaurant) then raise exception 'Role unavailable';end if;
 insert into tableflow_pilot.team_roles values(p_id,s.restaurant,trim(p_name),p_permissions) on conflict(id) do update set name=excluded.name,permissions=excluded.permissions;
 delete from tableflow_pilot.staff_sessions where staff in(select id from tableflow_pilot.staff where team_role=p_id);
 perform tableflow_pilot.ping(s.restaurant);return p_id;
end$$;
create or replace function public.tfp_team_save(p_token text,p_id uuid,p_username text,p_password text,p_role uuid,p_active boolean) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;a tableflow_pilot.staff;begin
 s=tableflow_pilot.authorize(p_token,'admin');perform 1 from tableflow_pilot.restaurants where id=s.restaurant for update;
 if p_id is null or p_username is null or p_username!~'^[A-Za-z0-9_.-]{3,40}$' or p_active is null then raise exception 'Enter a valid username and status';end if;
 if not exists(select 1 from tableflow_pilot.team_roles where id=p_role and restaurant=s.restaurant) then raise exception 'Choose a role belonging to this restaurant';end if;
 select * into a from tableflow_pilot.staff where id=p_id for update;
 if a.id is not null and (a.restaurant<>s.restaurant or a.role='manager') then raise exception 'Account unavailable';end if;
 if a.id is null or coalesce(p_password,'')<>'' then
 if p_password is null or length(p_password)<6 or octet_length(p_password)>72 or p_password!~'^[A-Za-z0-9]+$' or p_password!~'[A-Za-z]' or p_password!~'[0-9]' then raise exception 'Use at least 6 characters with letters and numbers only';end if;end if;
 insert into tableflow_pilot.staff(id,restaurant,username,pin_hash,role,active,team_role) values(p_id,s.restaurant,p_username,case when a.id is null then tableflow_pilot.pin_hash(p_password) else a.pin_hash end,'custom',p_active,p_role)
 on conflict(id) do update set username=excluded.username,role='custom',active=excluded.active,team_role=excluded.team_role,pin_hash=case when coalesce(p_password,'')='' then a.pin_hash else tableflow_pilot.pin_hash(p_password) end,failures=0,locked_until=null;
 delete from tableflow_pilot.staff_sessions where staff=p_id;perform tableflow_pilot.ping(s.restaurant);return p_id;
end$$;
create or replace function public.tfp_service_request(p_token text,p_kind text) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v uuid;i uuid;begin
 select visit into v from tableflow_pilot.guests where token_hash=tableflow_pilot.hash(p_token);
 perform 1 from tableflow_pilot.visits where id=v and closed is null for update;
 if not found or exists(select 1 from tableflow_pilot.guests where token_hash=tableflow_pilot.hash(p_token) and revoked) then raise exception 'This table session has ended';end if;
 if p_kind is null or p_kind not in ('Water','Call waiter','Cutlery','Help with bill') then raise exception 'Choose a service request';end if;
 insert into tableflow_pilot.service_requests(visit,kind) values(v,p_kind) on conflict(visit,kind) where not done do update set kind=excluded.kind returning id into i;
 perform tableflow_pilot.ping((select t.restaurant from tableflow_pilot.tables t join tableflow_pilot.visits x on x.table_id=t.id where x.id=v));return i;
end$$;
create or replace function public.tfp_service_done(p_token text,p_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 s=tableflow_pilot.authorize(p_token,'waiter');
 update tableflow_pilot.service_requests q set done=true from tableflow_pilot.visits v join tableflow_pilot.tables t on t.id=v.table_id where q.id=p_id and q.visit=v.id and t.restaurant=s.restaurant;
 if not found then raise exception 'Request unavailable';end if;perform tableflow_pilot.ping(s.restaurant);return jsonb_build_object('saved',true);
end$$;
create or replace function public.tfp_bill_format(p_token text,p_format jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 s=tableflow_pilot.authorize(p_token,'biller');
 if p_format is null or jsonb_typeof(p_format)<>'object' or length(coalesce(p_format->>'header',''))>300 or length(coalesce(p_format->>'footer',''))>300 or coalesce(p_format->>'paper','') not in ('58mm','80mm','A4') or jsonb_typeof(p_format->'showTax') is distinct from 'boolean' then raise exception 'Check header, footer, paper size and tax display';end if;
 update tableflow_pilot.restaurants set bill_format=jsonb_build_object('header',coalesce(p_format->>'header',''),'footer',coalesce(p_format->>'footer',''),'paper',p_format->>'paper','showTax',(p_format->>'showTax')::boolean) where id=s.restaurant;
 perform tableflow_pilot.ping(s.restaurant);return jsonb_build_object('saved',true);
end$$;
create or replace function public.tfp_workspace(p_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;p text[];r tableflow_pilot.restaurants;begin
 s=tableflow_pilot.authorize(p_token);p=tableflow_pilot.staff_permissions(s);select * into r from tableflow_pilot.restaurants where id=s.restaurant;
 return jsonb_build_object('name',r.name,'username',s.username,'permissions',p,'signal',r.signal,'format',case when 'biller'=any(p) then r.bill_format else null end,
 'tables',case when p&&array['waiter','kitchen','biller','dashboard'] then coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'number',t.number,'enabled',t.enabled,'qr',case when 'waiter'=any(p) then t.qr else null end) order by t.number) from tableflow_pilot.tables t where t.restaurant=s.restaurant),'[]'::jsonb) else '[]'::jsonb end,
 'visits',case when p&&array['waiter','kitchen','biller','dashboard'] then coalesce((select jsonb_agg(tableflow_pilot.visit_json(v.id)||jsonb_build_object('opened',v.opened,'tableId',v.table_id) order by v.opened) from tableflow_pilot.visits v join tableflow_pilot.tables t on t.id=v.table_id where t.restaurant=s.restaurant and (v.closed is null or v.closed>now()-interval '7 days')),'[]'::jsonb) else '[]'::jsonb end,
 'requests',case when 'waiter'=any(p) then coalesce((select jsonb_agg(jsonb_build_object('id',q.id,'kind',q.kind,'table',t.number,'created',q.created) order by q.created) from tableflow_pilot.service_requests q join tableflow_pilot.visits v on v.id=q.visit join tableflow_pilot.tables t on t.id=v.table_id where t.restaurant=s.restaurant and not q.done and v.closed is null),'[]'::jsonb) else '[]'::jsonb end,
 'roles',case when 'admin'=any(p) then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'permissions',permissions) order by name) from tableflow_pilot.team_roles where restaurant=s.restaurant),'[]'::jsonb) else '[]'::jsonb end,
 'team',case when 'admin'=any(p) then coalesce((select jsonb_agg(jsonb_build_object('id',id,'username',username,'role',role,'teamRole',team_role,'active',active) order by username) from tableflow_pilot.staff where restaurant=s.restaurant),'[]'::jsonb) else '[]'::jsonb end,
 'reviews',case when 'feedback'=any(p) then coalesce((select jsonb_agg(jsonb_build_object('id',id,'rating',rating,'comment',comment,'status',status,'resolution',resolution,'created',created) order by created desc) from tableflow_pilot.feedback where restaurant=s.restaurant),'[]'::jsonb) else '[]'::jsonb end);
end$$;

create or replace function public.tfp_open(p_token text,p_table uuid) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;t tableflow_pilot.tables;v uuid;new_code text;begin
 s=tableflow_pilot.authorize(p_token,'waiter');perform 1 from tableflow_pilot.restaurants where id=s.restaurant and active for share;if not found then raise exception 'Restaurant unavailable';end if;select * into t from tableflow_pilot.tables where id=p_table and restaurant=s.restaurant and enabled for update;
 if t.id is null then raise exception 'Table unavailable';end if;
 select id into v from tableflow_pilot.visits where table_id=t.id and closed is null;if v is not null then return v;end if;
 loop
 new_code=lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,8))::bit(32)::bigint)%100000000)::text,8,'0');
 exit when not exists(select 1 from tableflow_pilot.visits x where x.table_id=t.id and x.code=new_code);
 end loop;
 insert into tableflow_pilot.visits(table_id,code,tax) values(t.id,new_code,(select tax from tableflow_pilot.restaurants where id=s.restaurant)) returning id into v;perform tableflow_pilot.ping(s.restaurant);return v;end$$;
create or replace function public.tfp_settle(p_token text,p_visit uuid,p_total numeric) returns void
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;v tableflow_pilot.visits;subtotal numeric;total numeric;begin
 s=tableflow_pilot.authorize(p_token,'biller');
 select x.* into v from tableflow_pilot.visits x join tableflow_pilot.tables t on t.id=x.table_id where x.id=p_visit and t.restaurant=s.restaurant for update of x;
 if v.id is null then raise exception 'Visit unavailable';end if;
 if exists(select 1 from tableflow_pilot.orders where visit=v.id and status<>'Served') then raise exception 'Serve all orders before settling this visit';end if;
 select coalesce(sum((i->>'price')::numeric*(i->>'qty')::integer),0) into subtotal from tableflow_pilot.orders o cross join lateral jsonb_array_elements(o.items) i where o.visit=v.id;
 total=subtotal+round(subtotal*v.tax/100,2);
 if p_total is distinct from total then raise exception 'The bill changed. Refresh and confirm the current total before settling.';end if;
 update tableflow_pilot.visits set closed=coalesce(closed,now()),settled_total=total where id=v.id;perform tableflow_pilot.ping(s.restaurant);
end$$;
create or replace function public.tfp_owner_settings(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 s=tableflow_pilot.authorize(p_token,'menu');
 return jsonb_build_object('contract',(select jsonb_build_object('billing',c.billing,'monthly_amount',c.monthly_amount,'setup_amount',c.setup_amount,'currency',c.currency,'owner',c.owner_name) from tableflow_pilot.restaurant_contracts c where c.restaurant=s.restaurant and s.role='manager'),
 'menu',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'description',m.description,'price',m.price,'category',m.category,'veg',m.veg,'available',m.available,'image',m.image) order by m.category,m.name) from tableflow_pilot.menu m where m.restaurant=s.restaurant),'[]'::jsonb));
end$$;
create or replace function public.tfp_owner_save_dish(p_token text,p_id uuid,p_dish jsonb) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;existing tableflow_pilot.menu;begin
 s=tableflow_pilot.authorize(p_token,'menu');
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
create or replace function public.tfp_status(p_token text,p_order uuid,p_status text) returns void language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;o tableflow_pilot.orders;begin
 s=tableflow_pilot.authorize(p_token);if not('kitchen'=any(tableflow_pilot.staff_permissions(s))) and not(p_status='Served' and 'waiter'=any(tableflow_pilot.staff_permissions(s))) then raise exception 'Not permitted' using errcode='42501';end if;select a.* into o from tableflow_pilot.orders a join tableflow_pilot.visits v on v.id=a.visit join tableflow_pilot.tables t on t.id=v.table_id where a.id=p_order and t.restaurant=s.restaurant for update of a;
 if o.id is null then raise exception 'Order unavailable';end if;
 if o.status=p_status then return;end if;

 if not((o.status='Placed' and p_status='Preparing') or (o.status='Preparing' and p_status='Ready') or (o.status='Ready' and p_status='Served')) then raise exception 'Order status changed. Refresh and try again.';end if;
 update tableflow_pilot.orders set status=p_status where id=o.id;perform tableflow_pilot.ping(s.restaurant);end$$;
create or replace function public.tfp_resolve_review(p_token text,p_id uuid,p_status text,p_resolution text,p_admin boolean default false) returns void
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;r uuid;begin
 if p_admin then perform tableflow_pilot.admin_actor(p_token);else s=tableflow_pilot.authorize(p_token,'feedback');r=s.restaurant;end if;
 if p_status is null or p_status not in ('open','in_progress','resolved') or p_resolution is null or length(p_resolution)>2000 or (p_status='resolved' and length(trim(p_resolution))<3) then raise exception 'Choose a status and add a resolution note before resolving';end if;
 update tableflow_pilot.feedback set status=p_status,resolution=trim(p_resolution),updated=now() where id=p_id and (r is null or restaurant=r);
 if not found then raise exception 'Review unavailable';end if;
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
 if pw is null or length(pw)<6 or octet_length(pw)>72 or pw!~'^[A-Za-z0-9]+$' or pw!~'[A-Za-z]' or pw!~'[0-9]'
 then raise exception 'Use a password with 6 or more characters, letters and numbers only (maximum 72 bytes)';end if;
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
create or replace function public.tfp_admin_owner_access(p_token text,p_restaurant uuid,p_staff uuid,p_username text,p_password text default '') returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$
declare a uuid;s tableflow_pilot.staff;begin
 a=tableflow_pilot.admin_actor(p_token);
 select * into s from tableflow_pilot.staff where id=p_staff and restaurant=p_restaurant and role='manager' for update;
 if s.id is null then raise exception 'Owner account unavailable';end if;
 if p_username is null or trim(p_username)!~'^[A-Za-z0-9_.-]{3,40}$' then raise exception 'Use 3–40 letters, numbers, dots, underscores or hyphens for the username';end if;
 if p_password is null then raise exception 'Leave password blank to keep it unchanged';end if;
 if p_password<>'' and (length(p_password)<6 or octet_length(p_password)>72 or p_password!~'^[A-Za-z0-9]+$' or p_password!~'[A-Za-z]' or p_password!~'[0-9]') then raise exception 'Use at least 6 characters with letters and numbers only (maximum 72 bytes)';end if;
 if exists(select 1 from tableflow_pilot.staff where restaurant=p_restaurant and username=trim(p_username) and id<>p_staff) then raise exception 'This username is already used at the restaurant';end if;
 update tableflow_pilot.staff set username=trim(p_username),pin_hash=case when p_password='' then pin_hash else tableflow_pilot.pin_hash(p_password) end,failures=0,locked_until=null where id=p_staff;
 delete from tableflow_pilot.staff_sessions where staff=p_staff;
 insert into tableflow_pilot.owner_access_audit(admin,staff,username,password_reset) values(a,p_staff,trim(p_username),p_password<>'');
 return jsonb_build_object('saved',true);
end$$;
create or replace function public.tfp_owner_staff_save(p_token text,p_id uuid,p_username text,p_role text,p_active boolean,p_password text default '') returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;a tableflow_pilot.staff;begin
 s=tableflow_pilot.actor(p_token,array['manager']);
 if p_id is null or p_username is null or p_username!~'^[A-Za-z0-9_.-]{3,40}$' or p_role is null or p_role not in ('kitchen','waiter') or p_active is null then raise exception 'Enter a username and a kitchen or waiter role';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));select * into a from tableflow_pilot.staff where id=p_id for update;
 if a.id is not null and (a.restaurant<>s.restaurant or a.role='manager' or a.id=s.id) then raise exception 'This staff account cannot be changed here';end if;
 if a.id is null or coalesce(p_password,'')<>'' then
 if p_password is null or length(p_password)<6 or octet_length(p_password)>72 or p_password!~'^[A-Za-z0-9]+$' or p_password!~'[A-Za-z]' or p_password!~'[0-9]' then raise exception 'Use at least 6 characters with letters and numbers only (maximum 72 bytes)';end if;end if;
 if a.id is null then insert into tableflow_pilot.staff(id,restaurant,username,pin_hash,role,active) values(p_id,s.restaurant,p_username,tableflow_pilot.pin_hash(p_password),p_role,p_active);
 else update tableflow_pilot.staff set username=p_username,role=p_role,active=p_active,pin_hash=case when coalesce(p_password,'')='' then pin_hash else tableflow_pilot.pin_hash(p_password) end,failures=0,locked_until=null where id=p_id;end if;
 delete from tableflow_pilot.staff_sessions where staff=p_id;return p_id;
end$$;
revoke all on all functions in schema tableflow_pilot from public,anon,authenticated;
revoke all on function public.tfp_role_save(text,uuid,text,text[]),public.tfp_team_save(text,uuid,text,text,uuid,boolean),public.tfp_service_request(text,text),public.tfp_service_done(text,uuid),public.tfp_bill_format(text,jsonb),public.tfp_workspace(text) from public;
grant execute on function public.tfp_role_save(text,uuid,text,text[]),public.tfp_team_save(text,uuid,text,text,uuid,boolean),public.tfp_service_request(text,text),public.tfp_service_done(text,uuid),public.tfp_bill_format(text,jsonb),public.tfp_workspace(text) to anon,authenticated;
create or replace function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',6)$$;
commit;
