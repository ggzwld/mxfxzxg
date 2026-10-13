begin;

create or replace function public.post_menu_order_invoice_recognition(target_invoice_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  invoice_row public.books_invoices%rowtype;
  order_row public.menu_orders%rowtype;
  owner_user_id uuid;
  journal_id uuid;
  receivable_account_id uuid;
  revenue_account_id uuid;
  vat_account_id uuid;
  tips_account_id uuid;
begin
  select * into invoice_row
    from public.books_invoices
   where id = target_invoice_id;
  if not found or invoice_row.status <> 'paid' or invoice_row.invoice_number not like 'MENU-%' then return; end if;

  select * into order_row
    from public.menu_orders
   where order_number = substring(invoice_row.invoice_number from 6)
     and organization_id = invoice_row.organization_id;
  if not found or order_row.payment_status <> 'paid' then
    raise exception 'Paid menu order was not found for invoice %', invoice_row.invoice_number;
  end if;
  if invoice_row.total <> order_row.total_amount
     or invoice_row.subtotal <> order_row.subtotal
     or invoice_row.tax_amount <> order_row.tax_amount
     or coalesce(invoice_row.other_charges, 0) <> coalesce(order_row.service_fee, 0) + coalesce(order_row.tip_amount, 0) then
    raise exception 'Menu invoice totals do not match the paid order';
  end if;

  select owner_id into owner_user_id
    from public.books_organizations
   where id = invoice_row.organization_id;
  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (invoice_row.organization_id, '1000', 'Cash and bank', 'asset', true),
    (invoice_row.organization_id, '1100', 'Accounts receivable', 'asset', true),
    (invoice_row.organization_id, '2100', 'VAT payable', 'liability', true),
    (invoice_row.organization_id, '2300', 'Tips payable', 'liability', true),
    (invoice_row.organization_id, '4000', 'Sales revenue', 'income', true)
  on conflict (organization_id, code) do nothing;

  select id into receivable_account_id
    from public.books_accounts
   where organization_id = invoice_row.organization_id and code = '1100' and type = 'asset';
  select id into revenue_account_id
    from public.books_accounts
   where organization_id = invoice_row.organization_id and code = '4000' and type = 'income';
  select id into vat_account_id
    from public.books_accounts
   where organization_id = invoice_row.organization_id and code = '2100' and type = 'liability';
  select id into tips_account_id
    from public.books_accounts
   where organization_id = invoice_row.organization_id and code = '2300' and type = 'liability';
  if receivable_account_id is null or revenue_account_id is null or vat_account_id is null or tips_account_id is null then
    raise exception 'Required Books accounts are missing for the menu invoice';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (
    invoice_row.organization_id,
    'menu_order_invoice_recognition',
    invoice_row.id,
    invoice_row.issue_date,
    'Recognize menu sale ' || invoice_row.invoice_number,
    owner_user_id
  )
  on conflict do nothing
  returning id into journal_id;
  if journal_id is null then return; end if;

  insert into public.books_journal_lines (transaction_id, account_id, debit, currency_code)
  values (journal_id, receivable_account_id, invoice_row.total, invoice_row.currency_code);
  if order_row.subtotal + order_row.service_fee > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, revenue_account_id, order_row.subtotal + order_row.service_fee, invoice_row.currency_code);
  end if;
  if order_row.tax_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, vat_account_id, order_row.tax_amount, invoice_row.currency_code);
  end if;
  if order_row.tip_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, tips_account_id, order_row.tip_amount, invoice_row.currency_code);
  end if;
end;
$$;
revoke all on function public.post_menu_order_invoice_recognition(uuid) from public, anon, authenticated;
grant execute on function public.post_menu_order_invoice_recognition(uuid) to service_role;

create or replace function public.post_menu_order_business_books(target_order_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  order_row public.menu_orders%rowtype;
  invoice_row public.books_invoices%rowtype;
  seller_organization_id uuid;
  customer_contact_id uuid;
  invoice_uuid uuid;
  tax_uuid uuid;
  customer_name text;
  customer_email text;
  customer_phone text;
  profile_name text;
  profile_email text;
  profile_phone text;
  order_date date;
  tax_percentage numeric;
  organization_count integer;
  unmapped_item_count integer;
begin
  select * into order_row
    from public.menu_orders
   where id = target_order_id
   for update;
  if not found then raise exception 'Menu order was not found'; end if;
  if order_row.payment_status <> 'paid' then return 'not_paid'; end if;
  if order_row.total_amount <= 0 then raise exception 'A paid menu order must have a positive total'; end if;

  seller_organization_id := order_row.organization_id;
  if seller_organization_id is null then
    select count(distinct item.organization_id), count(*) filter (where item.organization_id is null),
           (array_agg(distinct item.organization_id) filter (where item.organization_id is not null))[1]
      into organization_count, unmapped_item_count, seller_organization_id
      from public.menu_order_items order_item
      left join public.menu_items item on item.id = order_item.menu_item_id
     where order_item.order_id = order_row.id;
    if organization_count <> 1 or unmapped_item_count <> 0 then
      raise exception 'Menu order does not map to exactly one hotel organization';
    end if;
    update public.menu_orders
       set organization_id = seller_organization_id
     where id = order_row.id and organization_id is null;
  end if;

  if exists (
    select 1
      from public.menu_order_items order_item
      left join public.menu_items item on item.id = order_item.menu_item_id
     where order_item.order_id = order_row.id
       and (item.id is null or item.organization_id is distinct from seller_organization_id)
  ) then
    raise exception 'Menu order contains items from another or unmapped hotel';
  end if;

  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (seller_organization_id, '1000', 'Cash and bank', 'asset', true),
    (seller_organization_id, '1100', 'Accounts receivable', 'asset', true),
    (seller_organization_id, '2100', 'VAT payable', 'liability', true),
    (seller_organization_id, '2300', 'Tips payable', 'liability', true),
    (seller_organization_id, '4000', 'Sales revenue', 'income', true)
  on conflict (organization_id, code) do nothing;

  customer_name := nullif(trim(concat_ws(' ', order_row.first_name, order_row.last_name)), '');
  customer_email := nullif(trim(order_row.email), '');
  customer_phone := nullif(trim(order_row.phone), '');
  if order_row.user_id is not null then
    select nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''),
           nullif(trim(profile.email), ''), nullif(trim(profile.phone), '')
      into profile_name, profile_email, profile_phone
      from public.user_profiles profile
     where profile.user_id = order_row.user_id;
    customer_name := coalesce(profile_name, customer_name);
    customer_email := coalesce(profile_email, customer_email);
    customer_phone := coalesce(profile_phone, customer_phone);
  end if;
  if customer_email is null then raise exception 'A customer email is required for the Books invoice'; end if;

  order_date := coalesce(order_row.created_at::date, current_date);
  select id into customer_contact_id
    from public.books_contacts
   where organization_id = seller_organization_id
     and lower(email) = lower(customer_email)
     and type in ('customer', 'both')
   order by created_at
   limit 1;
  if customer_contact_id is null then
    insert into public.books_contacts (organization_id, name, type, email, phone)
    values (seller_organization_id, coalesce(customer_name, customer_email), 'customer', customer_email, customer_phone)
    returning id into customer_contact_id;
  else
    update public.books_contacts
       set name = coalesce(customer_name, name), phone = coalesce(customer_phone, phone), updated_at = now()
     where id = customer_contact_id;
  end if;

  if order_row.tax_amount > 0 and order_row.subtotal > 0 then
    tax_percentage := round(order_row.tax_amount / order_row.subtotal * 100, 4);
    insert into public.books_tax_rates (organization_id, country_code, name, rate_percentage)
    values (seller_organization_id, 'UG', 'Menu sale tax ' || tax_percentage || '%', tax_percentage)
    on conflict (organization_id, name, effective_from) do nothing;
    select id into tax_uuid
      from public.books_tax_rates
     where organization_id = seller_organization_id
       and rate_percentage = tax_percentage
       and is_active
       and order_date >= effective_from
       and (effective_to is null or order_date <= effective_to)
     order by created_at desc
     limit 1;
  end if;

  if order_row.books_invoice_id is not null then
    select * into invoice_row
      from public.books_invoices
     where id = order_row.books_invoice_id;
    if not found or invoice_row.organization_id <> seller_organization_id
       or invoice_row.invoice_number <> 'MENU-' || order_row.order_number then
      raise exception 'The linked Books invoice does not belong to this menu order';
    end if;
    invoice_uuid := invoice_row.id;
  else
    select id into invoice_uuid
      from public.books_invoices
     where organization_id = seller_organization_id
       and invoice_number = 'MENU-' || order_row.order_number;
  end if;

  if invoice_uuid is null then
    insert into public.books_invoices (
      organization_id, contact_id, invoice_number, issue_date, due_date, currency_code,
      subtotal, tax_amount, tax_rate_id, status, notes
    ) values (
      seller_organization_id, customer_contact_id, 'MENU-' || order_row.order_number,
      order_date, order_date, upper(order_row.currency)::char(3), order_row.subtotal,
      order_row.tax_amount, tax_uuid, 'paid',
      'Digital menu order ' || order_row.order_number || ' (' || order_row.id || ')'
    ) returning id into invoice_uuid;
  end if;

  select * into invoice_row
    from public.books_invoices
   where id = invoice_uuid;
  if not found or invoice_row.status = 'void'
     or invoice_row.organization_id <> seller_organization_id
     or invoice_row.currency_code <> upper(order_row.currency)::char(3)
     or invoice_row.total <> order_row.total_amount then
    raise exception 'The Books invoice does not match the paid menu order';
  end if;
  if invoice_row.status <> 'paid' then
    update public.books_invoices set status = 'paid' where id = invoice_uuid;
    select * into invoice_row from public.books_invoices where id = invoice_uuid;
  end if;

  if not exists (select 1 from public.books_invoice_lines where invoice_id = invoice_uuid) then
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    select invoice_uuid, seller_organization_id, item_name, quantity, unit_price
      from public.menu_order_items
     where order_id = order_row.id;
  end if;
  if order_row.service_fee > 0 and not exists (
    select 1 from public.books_invoice_lines
     where invoice_id = invoice_uuid and description = 'Service fee'
  ) then
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    values (invoice_uuid, seller_organization_id, 'Service fee', 1, order_row.service_fee);
  end if;
  if order_row.tip_amount > 0 and not exists (
    select 1 from public.books_invoice_lines
     where invoice_id = invoice_uuid and description = 'Tip'
  ) then
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    values (invoice_uuid, seller_organization_id, 'Tip', 1, order_row.tip_amount);
  end if;

  perform public.post_books_journal_entry(
    seller_organization_id, 'invoice_payment', invoice_uuid, invoice_row.issue_date,
    'Payment received for invoice ' || invoice_row.invoice_number,
    '1000', '1100', invoice_row.total, invoice_row.currency_code,
    (select owner_id from public.books_organizations where id = seller_organization_id)
  );
  perform public.post_menu_order_invoice_recognition(invoice_uuid);

  update public.menu_orders
     set books_invoice_id = invoice_uuid,
         books_accounting_status = 'posted',
         books_accounting_error = null
   where id = order_row.id;
  return 'posted';
exception when others then
  update public.menu_orders
     set organization_id = coalesce(organization_id, seller_organization_id),
         books_accounting_status = 'failed',
         books_accounting_error = left(sqlerrm, 2000)
   where id = target_order_id;
  return 'failed';
end;
$$;
revoke all on function public.post_menu_order_business_books(uuid) from public, anon, authenticated;
grant execute on function public.post_menu_order_business_books(uuid) to service_role;

create or replace function public.post_paid_menu_order_to_books_v3()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.payment_status = 'paid'
     and (tg_op = 'INSERT' or old.payment_status is distinct from 'paid') then
    perform public.post_menu_order_business_books(new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.post_paid_menu_order_to_books_v3() from public, anon, authenticated;
drop trigger if exists menu_order_paid_books on public.menu_orders;
drop trigger if exists menu_order_paid_books_v2 on public.menu_orders;
drop trigger if exists menu_order_paid_books_v3 on public.menu_orders;
create trigger menu_order_paid_books_v3
  after insert or update of payment_status on public.menu_orders
  for each row execute function public.post_paid_menu_order_to_books_v3();

create or replace function public.retry_menu_order_business_books(target_order_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  order_row public.menu_orders%rowtype;
  posting_status text;
  seller_organization_id uuid;
  organization_count integer;
  unmapped_item_count integer;
begin
  select * into order_row
    from public.menu_orders
   where id = target_order_id
   for update;
  if not found then raise exception 'Menu order was not found'; end if;
  if order_row.payment_status <> 'paid' then raise exception 'Only paid menu orders can be posted to Business Books'; end if;
  seller_organization_id := order_row.organization_id;
  if seller_organization_id is null then
    select count(distinct item.organization_id), count(*) filter (where item.organization_id is null),
           (array_agg(distinct item.organization_id) filter (where item.organization_id is not null))[1]
      into organization_count, unmapped_item_count, seller_organization_id
      from public.menu_order_items order_item
      left join public.menu_items item on item.id = order_item.menu_item_id
     where order_item.order_id = order_row.id;
    if organization_count <> 1 or unmapped_item_count <> 0 then
      raise exception 'Menu order does not map to exactly one hotel organization';
    end if;
  end if;
  if not exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = seller_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ) then raise exception 'Not authorized to retry this hotel invoice'; end if;
  posting_status := public.post_menu_order_business_books(target_order_id);
  return posting_status;
end;
$$;
revoke all on function public.retry_menu_order_business_books(uuid) from public, anon;
grant execute on function public.retry_menu_order_business_books(uuid) to authenticated;

create or replace function public.get_books_currency_totals(target_organization_id uuid)
returns table (
  currency_code char(3), invoice_total numeric, income numeric, expenses numeric,
  net_result numeric, tax_total numeric, receivables numeric, assets numeric,
  liabilities numeric, equity numeric
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
begin
  if not exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id and membership.user_id = auth.uid()
  ) then raise exception 'Not authorized for this Books organization'; end if;

  return query
  with invoice_totals as (
    select invoice.currency_code::char(3) as currency_code,
      sum(invoice.total) filter (where invoice.status <> 'void') as invoice_total,
      sum(invoice.subtotal + coalesce(menu_order.service_fee, 0)) filter (where invoice.status in ('sent', 'overdue', 'paid')) as income,
      sum(invoice.tax_amount + case when menu_order.id is null then invoice.other_charges else 0 end) filter (where invoice.status <> 'void') as tax_total,
      sum(invoice.total) filter (where invoice.status in ('sent', 'overdue')) as receivables
    from public.books_invoices invoice
    left join lateral (
      select orders.id, orders.service_fee
        from public.menu_orders orders
       where orders.books_invoice_id = invoice.id
       limit 1
    ) menu_order on true
    where invoice.organization_id = target_organization_id
    group by invoice.currency_code
  ), expense_totals as (
    select expense.currency_code::char(3) as currency_code,
      sum(expense.amount + expense.tax_amount) as expenses
    from public.books_expenses expense
    where expense.organization_id = target_organization_id and expense.payment_status <> 'refunded'
    group by expense.currency_code
  ), ledger_totals as (
    select line.currency_code::char(3) as currency_code,
      sum(line.credit - line.debit) filter (where account.type = 'income') as income,
      sum(line.debit - line.credit) filter (where account.type = 'expense') as expenses,
      sum(line.debit - line.credit) filter (where account.type = 'asset') as assets,
      sum(line.credit - line.debit) filter (where account.type = 'liability') as liabilities,
      sum(line.credit - line.debit) filter (where account.type = 'equity') as equity
    from public.books_journal_lines line
    join public.books_journal_transactions transaction on transaction.id = line.transaction_id
    join public.books_accounts account on account.id = line.account_id
    where transaction.organization_id = target_organization_id
    group by line.currency_code
  ), currencies as (
    select currency_code from invoice_totals
    union select currency_code from expense_totals
    union select currency_code from ledger_totals
  )
  select currencies.currency_code,
    coalesce(invoice_totals.invoice_total, 0), coalesce(invoice_totals.income, 0), coalesce(expense_totals.expenses, 0),
    coalesce(invoice_totals.income, 0) - coalesce(expense_totals.expenses, 0),
    coalesce(invoice_totals.tax_total, 0), coalesce(invoice_totals.receivables, 0),
    coalesce(ledger_totals.assets, 0), coalesce(ledger_totals.liabilities, 0),
    coalesce(ledger_totals.equity, 0) + coalesce(invoice_totals.income, 0) - coalesce(expense_totals.expenses, 0)
  from currencies
  left join invoice_totals using (currency_code)
  left join expense_totals using (currency_code)
  left join ledger_totals using (currency_code)
  order by currencies.currency_code;
end;
$$;
revoke all on function public.get_books_currency_totals(uuid) from public, anon;
grant execute on function public.get_books_currency_totals(uuid) to authenticated;

do $$
declare
  target_order_id uuid;
begin
  for target_order_id in
    select orders.id
      from public.menu_orders orders
     where orders.payment_status = 'paid'
       and (
         orders.books_invoice_id is null
         or orders.books_accounting_status is distinct from 'posted'
         or not exists (
           select 1
             from public.books_journal_transactions recognition
            where recognition.organization_id = orders.organization_id
              and recognition.source_type = 'menu_order_invoice_recognition'
              and recognition.source_id = orders.books_invoice_id
         )
         or not exists (
           select 1
             from public.books_journal_transactions payment
            where payment.organization_id = orders.organization_id
              and payment.source_type = 'invoice_payment'
              and payment.source_id = orders.books_invoice_id
         )
       )
     order by orders.created_at
  loop
    perform public.post_menu_order_business_books(target_order_id);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
commit;
