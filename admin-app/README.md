# Admin App (Expo)

Painel admin mobile do NextPlay Club — paridade com `admin.html` + tela de **Lucro** e push ao cruzar R$ 600.

## Setup

1. Rode no Supabase SQL Editor:
   - `supabase/player-profit.sql`
2. Deploy da Edge Function:
   ```bash
   supabase functions deploy notify-admin-profit
   ```
3. No app:
   ```bash
   cd admin-app
   npm install
   npx expo start
   ```
4. Entre com conta `profiles.is_admin = true` (Expo Go ou device).
5. Aceite notificações — o token é salvo via `admin_register_push_token`.

## Teste do alerta ≥ 600

Na aba **Jogadores**, aumente créditos de uma conta teste até o lucro líquido
`(créditos + saques pagos − depósitos pagos)` cruzar R$ 600. O push “Lucro alto”
deve chegar nos devices admin com token registrado. A aba **Lucro** lista o ranking
e permite rechecar o alerta.
