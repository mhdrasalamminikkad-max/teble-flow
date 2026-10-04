-- Apply after 007. Existing invoice amounts/payments remain unchanged.
begin;
alter table tableflow_pilot.restaurant_contracts add column if not exists billing_start date not null default (now() at time zone 'Asia/Kolkata')::date;
create table if not exists tableflow_pilot.owner_access_audit(id uuid primary key default gen_random_uuid(),admin uuid not null references tableflow_pilot.platform_admins(id),staff uuid not null references tableflow_pilot.staff(id),username text not null,password_reset boolean not null,created timestamptz not null default now());
revoke all on tableflow_pilot.owner_access_audit from public,anon,authenticated;
create or replace function public.tfp_admin_owner_access(p_token text,p_restaurant uuid,p_staff uuid,p_username text,p_password text default '') returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$
declare a uuid;s tableflow_pilot.staff;begin
 a=tableflow_pilot.admin_actor(p_token);
 select * into s from tableflow_pilot.staff where id=p_staff and restaurant=p_restaurant and role='manager' for update;
 if s.id is null then raise exception 'Owner account unavailable';end if;
 if p_username is null or trim(p_username)!~'^[A-Za-z0-9_.-]{3,40}$' then raise exception 'Use 3–40 letters, numbers, dots, underscores or hyphens for the username';end if;
 if p_password is null then raise exception 'Leave password blank to keep it unchanged';end if;
 if p_password<>'' and (length(p_password)<12 or octet_length(p_password)>72 or p_password!~'[A-Za-z]' or p_password!~'[0-9]') then raise exception 'Use at least 12 characters with letters and numbers (maximum 72 bytes)';end if;
 if exists(select 1 from tableflow_pilot.staff where restaurant=p_restaurant and username=trim(p_username) and id<>p_staff) then raise exception 'This username is already used at the restaurant';end if;
 update tableflow_pilot.staff set username=trim(p_username),pin_hash=case when p_password='' then pin_hash else tableflow_pilot.pin_hash(p_password) end,failures=0,locked_until=null where id=p_staff;
 delete from tableflow_pilot.staff_sessions where staff=p_staff;
 insert into tableflow_pilot.owner_access_audit(admin,staff,username,password_reset) values(a,p_staff,trim(p_username),p_password<>'');
 return jsonb_build_object('saved',true);
end$$;
create or replace function tableflow_pilot.generate_pending_invoices(p_today date,p_restaurant uuid default null) returns void
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$
begin
 -- Never change already-issued invoices; the unique key makes repeat refreshes safe.
 insert into tableflow_pilot.invoices(restaurant,kind,period,amount,due)
 select c.restaurant,'monthly',to_char(m.period,'YYYY-MM'),c.monthly_amount,greatest(m.period::date,c.billing_start)+7
 from tableflow_pilot.restaurant_contracts c join tableflow_pilot.restaurants r on r.id=c.restaurant
 cross join lateral generate_series(date_trunc('month',c.billing_start::timestamp),date_trunc('month',p_today::timestamp),interval '1 month') m(period)
 where r.active and c.billing in ('monthly','both') and c.monthly_amount>0 and c.billing_start<=p_today and (p_restaurant is null or c.restaurant=p_restaurant)
 on conflict(restaurant,kind,period) do nothing;
 insert into tableflow_pilot.invoices(restaurant,kind,period,amount,due)
 select c.restaurant,'setup','setup',c.setup_amount,c.billing_start+7 from tableflow_pilot.restaurant_contracts c join tableflow_pilot.restaurants r on r.id=c.restaurant
 where r.active and c.billing in ('one_time','both') and c.setup_amount>0 and c.billing_start<=p_today and (p_restaurant is null or c.restaurant=p_restaurant)
 on conflict(restaurant,kind,period) do nothing;
end$$;
revoke all on function tableflow_pilot.generate_pending_invoices(date,uuid) from public,anon,authenticated;
create or replace function public.tfp_admin_restaurants(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$begin
 perform tableflow_pilot.admin_actor(p_token);
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'slug',r.slug,'active',r.active,
 'tables',(select count(*) from tableflow_pilot.tables t where t.restaurant=r.id),'owner',c.owner_name,
 'contact',c.contact,'billing',c.billing,'monthly_amount',c.monthly_amount,'setup_amount',c.setup_amount,'currency','INR','billing_start',c.billing_start,'owners',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'username',s.username,'active',s.active) order by s.username) from tableflow_pilot.staff s where s.restaurant=r.id and s.role='manager'),'[]'::jsonb)) order by r.name)
 from tableflow_pilot.restaurants r left join tableflow_pilot.restaurant_contracts c on c.restaurant=r.id),'[]'::jsonb);
end$$;
create or replace function public.tfp_operations(p_token text,p_admin boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare r uuid;s tableflow_pilot.staff;begin
 if p_admin then perform tableflow_pilot.admin_actor(p_token);else s=tableflow_pilot.actor(p_token,array['manager']);r=s.restaurant;end if;
 perform tableflow_pilot.generate_pending_invoices((now() at time zone 'Asia/Kolkata')::date,r);
 return jsonb_build_object(
 'invoices',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'restaurant',i.restaurant,'name',x.name,'kind',i.kind,'period',i.period,'amount',i.amount,'paid',coalesce((select sum(p.amount) from tableflow_pilot.payments p where p.invoice=i.id),0),'due',i.due) order by i.due desc) from tableflow_pilot.invoices i join tableflow_pilot.restaurants x on x.id=i.restaurant where r is null or i.restaurant=r),'[]'::jsonb),
 'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',x.name,'invoice',p.invoice,'amount',p.amount,'reference',p.reference,'created',p.created) order by p.created desc) from tableflow_pilot.payments p join tableflow_pilot.invoices i on i.id=p.invoice join tableflow_pilot.restaurants x on x.id=i.restaurant where r is null or i.restaurant=r),'[]'::jsonb),
 'reviews',coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'restaurant',f.restaurant,'name',x.name,'source',f.source,'rating',f.rating,'comment',f.comment,'source_url',f.source_url,'status',f.status,'resolution',f.resolution,'created',f.created) order by f.created desc) from tableflow_pilot.feedback f join tableflow_pilot.restaurants x on x.id=f.restaurant where r is null or f.restaurant=r),'[]'::jsonb),
 'tables',case when r is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'number',t.number,'enabled',t.enabled,'qr',t.qr,'occupied',exists(select 1 from tableflow_pilot.visits v where v.table_id=t.id and v.closed is null)) order by t.number) from tableflow_pilot.tables t where t.restaurant=r),'[]'::jsonb) end,
 'staff',case when r is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'username',a.username,'role',a.role,'active',a.active,'self',a.id=s.id) order by a.username) from tableflow_pilot.staff a where a.restaurant=r),'[]'::jsonb) end,
 'sales',case when r is null then null else (select jsonb_build_object('settled',coalesce(sum(tableflow_pilot.visit_total(v.id)) filter(where v.closed is not null),0),'unsettled',coalesce(sum(tableflow_pilot.visit_total(v.id)) filter(where v.closed is null),0),'completed_visits',count(*) filter(where v.closed is not null)) from tableflow_pilot.visits v join tableflow_pilot.tables t on t.id=v.table_id where t.restaurant=r) end);
end$$;
revoke all on function public.tfp_admin_owner_access(text,uuid,uuid,text,text) from public;
grant execute on function public.tfp_admin_owner_access(text,uuid,uuid,text,text) to anon,authenticated;
create or replace function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',5)$$;
commit;
