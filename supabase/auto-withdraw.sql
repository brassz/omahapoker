-- Saque automático: devolve saldo se o PIX CajuPay falhar ao solicitar.
-- Rode no SQL Editor do Supabase (depois de cajupay.sql / withdrawals.sql).

create or replace function public.service_reject_withdrawal(
  p_id uuid,
  p_note text default null
)
returns public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.withdrawals;
begin
  select * into row
  from public.withdrawals
  where id = p_id and status = 'pending'
  for update;

  if row.id is null then
    return null;
  end if;

  update public.profiles
  set player_credits = player_credits + row.amount
  where id = row.user_id;

  update public.withdrawals
  set
    status = 'rejected',
    processed_at = now(),
    admin_note = coalesce(
      nullif(trim(coalesce(p_note, '')), ''),
      'PIX automático falhou. Saldo devolvido.'
    )
  where id = p_id
  returning * into row;

  return row;
end;
$$;

revoke all on function public.service_reject_withdrawal(uuid, text) from public, anon, authenticated;
grant execute on function public.service_reject_withdrawal(uuid, text) to service_role;
