-- TABLEFLOW operations upgrade. Apply after 004. Does not reset credentials.
begin;
alter table tableflow_pilot.tables add column if not exists enabled boolean not null default true;
create table if not exists tableflow_pilot.invoices(
 id uuid primary key default gen_random_uuid(),restaurant uuid not null references tableflow_pilot.restaurants(id),
 kind text not null check(kind in ('monthly','setup')),period text not null,amount numeric(12,2) not null check(amount>0),
 due date not null,created timestamptz not null default now(),unique(restaurant,kind,period)
);
create table if not exists tableflow_pilot.payments(
 id uuid primary key,invoice uuid not null references tableflow_pilot.invoices(id),amount numeric(12,2) not null check(amount>0),
 reference text not null,recorded_by uuid not null references tableflow_pilot.platform_admins(id),created timestamptz not null default now()
);
create table if not exists tableflow_pilot.feedback(
 id uuid primary key,restaurant uuid not null references tableflow_pilot.restaurants(id),visit uuid references tableflow_pilot.visits(id),guest_hash bytea,
 source text not null check(source in ('tableflow','google')),rating integer not null check(rating between 1 and 5),
 comment text not null check(length(comment)<=2000),source_url text not null default '',status text not null default 'open' check(status in ('open','in_progress','resolved')),
 resolution text not null default '',created timestamptz not null default now(),updated timestamptz not null default now(),unique(visit,guest_hash)
);
create unique index if not exists tfp_google_review_unique on tableflow_pilot.feedback(restaurant,source_url) where source='google';
revoke all on all tables in schema tableflow_pilot from public,anon,authenticated;

create or replace function tableflow_pilot.visit_total(p_visit uuid) returns numeric language sql stable set search_path=pg_catalog,tableflow_pilot as $$
 select coalesce(sum((i->>'price')::numeric*(i->>'qty')::int),0)+round(coalesce(sum((i->>'price')::numeric*(i->>'qty')::int),0)*v.tax/100,2)
 from tableflow_pilot.visits v left join tableflow_pilot.orders o on o.visit=v.id left join lateral jsonb_array_elements(o.items) i on true where v.id=p_visit group by v.tax
$$;
create or replace function public.tfp_operations(p_token text,p_admin boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare r uuid;s tableflow_pilot.staff;begin
 if p_admin then perform tableflow_pilot.admin_actor(p_token);else s=tableflow_pilot.actor(p_token,array['manager']);r=s.restaurant;end if;
 return jsonb_build_object(
 'invoices',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'restaurant',i.restaurant,'name',x.name,'kind',i.kind,'period',i.period,'amount',i.amount,'paid',coalesce((select sum(p.amount) from tableflow_pilot.payments p where p.invoice=i.id),0),'due',i.due) order by i.due desc) from tableflow_pilot.invoices i join tableflow_pilot.restaurants x on x.id=i.restaurant where r is null or i.restaurant=r),'[]'::jsonb),
 'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',x.name,'invoice',p.invoice,'amount',p.amount,'reference',p.reference,'created',p.created) order by p.created desc) from tableflow_pilot.payments p join tableflow_pilot.invoices i on i.id=p.invoice join tableflow_pilot.restaurants x on x.id=i.restaurant where r is null or i.restaurant=r),'[]'::jsonb),
 'reviews',coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'restaurant',f.restaurant,'name',x.name,'source',f.source,'rating',f.rating,'comment',f.comment,'source_url',f.source_url,'status',f.status,'resolution',f.resolution,'created',f.created) order by f.created desc) from tableflow_pilot.feedback f join tableflow_pilot.restaurants x on x.id=f.restaurant where r is null or f.restaurant=r),'[]'::jsonb),
 'tables',case when r is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'number',t.number,'enabled',t.enabled,'qr',t.qr,'occupied',exists(select 1 from tableflow_pilot.visits v where v.table_id=t.id and v.closed is null)) order by t.number) from tableflow_pilot.tables t where t.restaurant=r),'[]'::jsonb) end,
 'staff',case when r is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'username',a.username,'role',a.role,'active',a.active,'self',a.id=s.id) order by a.username) from tableflow_pilot.staff a where a.restaurant=r),'[]'::jsonb) end,
 'sales',case when r is null then null else (select jsonb_build_object('settled',coalesce(sum(tableflow_pilot.visit_total(v.id)) filter(where v.closed is not null),0),'unsettled',coalesce(sum(tableflow_pilot.visit_total(v.id)) filter(where v.closed is null),0),'completed_visits',count(*) filter(where v.closed is not null)) from tableflow_pilot.visits v join tableflow_pilot.tables t on t.id=v.table_id where t.restaurant=r) end);
end$$;

create or replace function public.tfp_admin_invoice(p_token text,p_restaurant uuid,p_kind text,p_period text,p_due date) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare c tableflow_pilot.restaurant_contracts;a numeric;i uuid;begin
 perform tableflow_pilot.admin_actor(p_token);
 select * into c from tableflow_pilot.restaurant_contracts where restaurant=p_restaurant for update;
 if c.restaurant is null then raise exception 'Assign a billing plan before raising an invoice';end if;
 if p_kind is null or p_kind not in ('monthly','setup') or p_due is null then raise exception 'Choose an invoice type and due date';end if;
 if p_kind='monthly' and (p_period is null or p_period!~'^[0-9]{4}-(0[1-9]|1[0-2])$') then raise exception 'Use a billing month in YYYY-MM format';end if;
 if p_kind='setup' then p_period='setup';end if;
 select id into i from tableflow_pilot.invoices where restaurant=p_restaurant and kind=p_kind and period=p_period;if i is not null then return i;end if;
 a=case when p_kind='monthly' then c.monthly_amount else c.setup_amount end;if a<=0 then raise exception 'No charge is assigned for this invoice type';end if;
 insert into tableflow_pilot.invoices(restaurant,kind,period,amount,due) values(p_restaurant,p_kind,p_period,a,p_due) returning id into i;return i;
end$$;
create or replace function public.tfp_admin_payment(p_token text,p_request uuid,p_invoice uuid,p_amount numeric,p_reference text) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare a uuid;i tableflow_pilot.invoices;old tableflow_pilot.payments;paid numeric;begin
 a=tableflow_pilot.admin_actor(p_token);
 if p_request is null then raise exception 'Missing payment request';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into old from tableflow_pilot.payments where id=p_request;
 if old.id is not null then if old.invoice is distinct from p_invoice or old.amount is distinct from p_amount or old.reference is distinct from trim(p_reference) then raise exception 'Payment retry details changed';end if;return old.id;end if;
 select * into i from tableflow_pilot.invoices where id=p_invoice for update;if i.id is null then raise exception 'Invoice unavailable';end if;
 select coalesce(sum(amount),0) into paid from tableflow_pilot.payments where invoice=i.id;
 if p_amount is null or p_amount<=0 or p_amount>i.amount-paid or p_amount<>round(p_amount,2) or coalesce(length(trim(p_reference)),0) not between 3 and 120 then raise exception 'Enter a valid amount within the outstanding balance and a payment reference';end if;
 insert into tableflow_pilot.payments(id,invoice,amount,reference,recorded_by) values(p_request,i.id,p_amount,trim(p_reference),a);return p_request;
end$$;

create or replace function public.tfp_admin_manage(p_token text,p_restaurant uuid,p_name text,p_active boolean) returns void
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$begin
 perform tableflow_pilot.admin_actor(p_token);perform 1 from tableflow_pilot.restaurants where id=p_restaurant for update;
 if not found then raise exception 'Restaurant unavailable';end if;
 if coalesce(length(trim(p_name)),0) not between 2 and 100 or p_active is null then raise exception 'Enter a restaurant name and status';end if;
 if not p_active and exists(select 1 from tableflow_pilot.visits v join tableflow_pilot.tables t on t.id=v.table_id where t.restaurant=p_restaurant and v.closed is null) then raise exception 'Close all active table visits before pausing this restaurant';end if;
 update tableflow_pilot.restaurants set name=trim(p_name),active=p_active where id=p_restaurant;
 if not p_active then delete from tableflow_pilot.staff_sessions where staff in(select id from tableflow_pilot.staff where restaurant=p_restaurant);end if;
 perform tableflow_pilot.ping(p_restaurant);
end$$;

create or replace function public.tfp_owner_table(p_token text,p_number integer,p_enabled boolean) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;t tableflow_pilot.tables;begin
 s=tableflow_pilot.actor(p_token,array['manager']);
 if p_number is null or p_number not between 1 and 100 or p_enabled is null then raise exception 'Choose a table number from 1 to 100';end if;
 perform 1 from tableflow_pilot.restaurants where id=s.restaurant for update;
 select * into t from tableflow_pilot.tables where restaurant=s.restaurant and number=p_number for update;
 if t.id is null then insert into tableflow_pilot.tables(restaurant,number,enabled) values(s.restaurant,p_number,p_enabled) returning * into t;
 else if not p_enabled and exists(select 1 from tableflow_pilot.visits where table_id=t.id and closed is null) then raise exception 'Close the table visit before disabling this table';end if;
 update tableflow_pilot.tables set enabled=p_enabled where id=t.id;end if;
 perform tableflow_pilot.ping(s.restaurant);return t.id;
end$$;

create or replace function public.tfp_owner_staff_save(p_token text,p_id uuid,p_username text,p_role text,p_active boolean,p_password text default '') returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;a tableflow_pilot.staff;begin
 s=tableflow_pilot.actor(p_token,array['manager']);
 if p_id is null or p_username is null or p_username!~'^[A-Za-z0-9_.-]{3,40}$' or p_role is null or p_role not in ('kitchen','waiter') or p_active is null then raise exception 'Enter a username and a kitchen or waiter role';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));select * into a from tableflow_pilot.staff where id=p_id for update;
 if a.id is not null and (a.restaurant<>s.restaurant or a.role='manager' or a.id=s.id) then raise exception 'This staff account cannot be changed here';end if;
 if a.id is null or coalesce(p_password,'')<>'' then
 if p_password is null or length(p_password)<12 or octet_length(p_password)>72 or p_password!~'[A-Za-z]' or p_password!~'[0-9]' then raise exception 'Use at least 12 characters with letters and numbers (maximum 72 bytes)';end if;end if;
 if a.id is null then insert into tableflow_pilot.staff(id,restaurant,username,pin_hash,role,active) values(p_id,s.restaurant,p_username,tableflow_pilot.pin_hash(p_password),p_role,p_active);
 else update tableflow_pilot.staff set username=p_username,role=p_role,active=p_active,pin_hash=case when coalesce(p_password,'')='' then pin_hash else tableflow_pilot.pin_hash(p_password) end,failures=0,locked_until=null where id=p_id;end if;
 delete from tableflow_pilot.staff_sessions where staff=p_id;return p_id;
end$$;

create or replace function public.tfp_guest_review(p_token text,p_rating integer,p_comment text) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v uuid;r uuid;f uuid;h bytea;begin
 h=tableflow_pilot.hash(p_token);select visit into v from tableflow_pilot.guests where token_hash=h;
 if v is null or not exists(select 1 from tableflow_pilot.orders where visit=v) then raise exception 'Place an order before reviewing this visit';end if;
 if p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>2000 then raise exception 'Choose 1–5 stars and keep feedback within 2000 characters';end if;
 select t.restaurant into r from tableflow_pilot.visits x join tableflow_pilot.tables t on t.id=x.table_id where x.id=v;
 insert into tableflow_pilot.feedback(id,restaurant,visit,guest_hash,source,rating,comment) values(gen_random_uuid(),r,v,h,'tableflow',p_rating,trim(p_comment))
 on conflict(visit,guest_hash) do update set rating=excluded.rating,comment=excluded.comment,status='open',resolution='',updated=now() returning id into f;return f;
end$$;
create or replace function public.tfp_google_review(p_token text,p_id uuid,p_rating integer,p_comment text,p_url text) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 s=tableflow_pilot.actor(p_token,array['manager']);
 if p_id is null or p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>2000 or p_url is null or length(p_url)>1000
 or p_url!~'^https://(www\.google\.com/maps/|maps\.google\.com/|maps\.app\.goo\.gl/|g\.co/kgs/)' then raise exception 'Enter a rating, review text and a Google Maps review link';end if;
 insert into tableflow_pilot.feedback(id,restaurant,source,rating,comment,source_url) values(p_id,s.restaurant,'google',p_rating,trim(p_comment),p_url)
 on conflict(restaurant,source_url) where source='google' do nothing;
 return (select id from tableflow_pilot.feedback where restaurant=s.restaurant and source_url=p_url and source='google');
end$$;
create or replace function public.tfp_resolve_review(p_token text,p_id uuid,p_status text,p_resolution text,p_admin boolean default false) returns void
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;r uuid;begin
 if p_admin then perform tableflow_pilot.admin_actor(p_token);else s=tableflow_pilot.actor(p_token,array['manager']);r=s.restaurant;end if;
 if p_status is null or p_status not in ('open','in_progress','resolved') or p_resolution is null or length(p_resolution)>2000 or (p_status='resolved' and length(trim(p_resolution))<3) then raise exception 'Choose a status and add a resolution note before resolving';end if;
 update tableflow_pilot.feedback set status=p_status,resolution=trim(p_resolution),updated=now() where id=p_id and (r is null or restaurant=r);
 if not found then raise exception 'Review unavailable';end if;
end$$;

create or replace function public.tfp_menu(p_qr uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare t tableflow_pilot.tables;r tableflow_pilot.restaurants;begin
 select * into t from tableflow_pilot.tables where qr=p_qr and enabled;select * into r from tableflow_pilot.restaurants where id=t.restaurant and active;
 if r.id is null then raise exception 'This table is unavailable';end if;
 return jsonb_build_object('name',r.name,'restaurant',r.id,'table',t.number,'wait',r.wait,'signal',r.signal,'dishes',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'description',m.description,'price',m.price,'category',m.category,'veg',m.veg,'image',m.image,'available',m.available) order by m.category,m.name) from tableflow_pilot.menu m where m.restaurant=r.id),'[]'::jsonb));end$$;
create or replace function public.tfp_open(p_token text,p_table uuid) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;t tableflow_pilot.tables;v uuid;new_code text;begin
 s=tableflow_pilot.actor(p_token,array['manager','waiter']);perform 1 from tableflow_pilot.restaurants where id=s.restaurant and active for share;if not found then raise exception 'Restaurant unavailable';end if;select * into t from tableflow_pilot.tables where id=p_table and restaurant=s.restaurant and enabled for update;
 if t.id is null then raise exception 'Table unavailable';end if;
 select id into v from tableflow_pilot.visits where table_id=t.id and closed is null;if v is not null then return v;end if;
 loop
 new_code=lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,8))::bit(32)::bigint)%100000000)::text,8,'0');
 exit when not exists(select 1 from tableflow_pilot.visits x where x.table_id=t.id and x.code=new_code);
 end loop;
 insert into tableflow_pilot.visits(table_id,code,tax) values(t.id,new_code,(select tax from tableflow_pilot.restaurants where id=s.restaurant)) returning id into v;perform tableflow_pilot.ping(s.restaurant);return v;end$$;
create or replace function public.tfp_join(p_qr uuid,p_code text,p_guest_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v tableflow_pilot.visits;t tableflow_pilot.tables;h bytea;begin
 if p_guest_token is null or p_guest_token!~'^[a-f0-9]{64}$' then raise exception 'Invalid guest token';end if;
 select a.* into t from tableflow_pilot.tables a join tableflow_pilot.restaurants r on r.id=a.restaurant where a.qr=p_qr and a.enabled and r.active;
 select * into v from tableflow_pilot.visits where table_id=t.id and closed is null for update;
 if v.id is null then return jsonb_build_object('error','Ask staff to open your table visit.');end if;
 h=tableflow_pilot.hash(p_guest_token);
 if exists(select 1 from tableflow_pilot.guests where token_hash=h and visit=v.id) then return tableflow_pilot.visit_json(v.id);end if;
 if v.locked_until>now() then return jsonb_build_object('error','Please wait a minute and ask staff to confirm your visit code.');end if;
 if p_code is distinct from v.code then
 update tableflow_pilot.visits set failures=case when failures>=9 then 0 else failures+1 end,locked_until=case when failures>=9 then now()+interval '1 minute' else null end where id=v.id;
 return jsonb_build_object('error','Visit code is incorrect. Ask your waiter.');end if;
 if (select count(*) from tableflow_pilot.guests where visit=v.id)>=16 then return jsonb_build_object('error','This visit has reached its device limit. Ask staff for help.');end if;
 insert into tableflow_pilot.guests values(h,v.id);return tableflow_pilot.visit_json(v.id);end$$;
create or replace function public.tfp_staff(p_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;r tableflow_pilot.restaurants;begin
 s=tableflow_pilot.actor(p_token);select * into r from tableflow_pilot.restaurants where id=s.restaurant;
 return jsonb_build_object('name',r.name,'role',s.role,'signal',r.signal,'tables',(select jsonb_agg(jsonb_build_object('id',t.id,'number',t.number,'enabled',t.enabled,'qr',t.qr,'visit',(select jsonb_build_object('id',v.id,'code',case when s.role in ('manager','waiter') then v.code else null end) from tableflow_pilot.visits v where v.table_id=t.id and v.closed is null)) order by t.number) from tableflow_pilot.tables t where t.restaurant=r.id),'visits',coalesce((select jsonb_agg(tableflow_pilot.visit_json(v.id) order by v.opened desc) from tableflow_pilot.visits v join tableflow_pilot.tables t on t.id=v.table_id where t.restaurant=r.id and (v.closed is null or v.closed>now()-interval '1 day')),'[]'::jsonb));end$$;

revoke all on all functions in schema tableflow_pilot from public,anon,authenticated;
revoke all on function public.tfp_operations(text,boolean),public.tfp_admin_invoice(text,uuid,text,text,date),public.tfp_admin_payment(text,uuid,uuid,numeric,text),public.tfp_admin_manage(text,uuid,text,boolean),public.tfp_owner_table(text,integer,boolean),public.tfp_owner_staff_save(text,uuid,text,text,boolean,text),public.tfp_guest_review(text,integer,text),public.tfp_google_review(text,uuid,integer,text,text),public.tfp_resolve_review(text,uuid,text,text,boolean) from public;
grant execute on function public.tfp_operations(text,boolean),public.tfp_admin_invoice(text,uuid,text,text,date),public.tfp_admin_payment(text,uuid,uuid,numeric,text),public.tfp_admin_manage(text,uuid,text,boolean),public.tfp_owner_table(text,integer,boolean),public.tfp_owner_staff_save(text,uuid,text,text,boolean,text),public.tfp_guest_review(text,integer,text),public.tfp_google_review(text,uuid,integer,text,text),public.tfp_resolve_review(text,uuid,text,text,boolean) to anon,authenticated;
create or replace function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',3)$$;
commit;
