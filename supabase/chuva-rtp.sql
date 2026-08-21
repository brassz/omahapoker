-- Desliga o RTP próprio do Chuva de Prêmios (volta ao plinko físico normal).
-- Rode no SQL Editor se você já tiver aplicado supabase/chuva-rtp.sql antes.

drop function if exists public.next_chuva_multiplier();
drop function if exists public.admin_reset_chuva_counter();
drop function if exists public.admin_save_chuva_rtp(numeric[], json, integer);
drop function if exists public.get_chuva_rtp();

drop table if exists public.chuva_rtp_rules;
drop table if exists public.chuva_rtp_config;

-- Garante que o RTP por jogo não force manipulação no Chuva
update public.game_rtp
set enabled = false, updated_at = now()
where game_id = 'chuvadepremios';
