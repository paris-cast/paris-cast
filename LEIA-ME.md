# Paris Cast: como colocar no ar (GitHub + Supabase)

Tempo: cerca de 20 minutos. Tudo gratuito. Faça na ordem.

## Parte 1: o banco de dados (Supabase)

1. Entre em **supabase.com**, crie uma conta (pode ser com o GitHub) e clique em **New project**.
   - Nome: `paris-cast`
   - Database password: invente uma senha forte e guarde.
   - Region: **South America (São Paulo)**.
   - Espere uns 2 minutos até o projeto ficar pronto.
2. No menu da esquerda, abra **SQL Editor** > **New query**. Abra o arquivo `supabase.sql` desta pasta, copie **tudo**, cole e clique em **Run**. Deve aparecer "Success".
3. Abra **Authentication** e ligue o login anônimo:
   - Em **Sign In / Providers** (ou **Providers**), ative **Anonymous Sign-Ins**.
   - Ainda em Providers, abra **Email** e **desligue "Confirm email"**. Assim você entra como dono sem precisar confirmar e-mail.
   (Os nomes podem mudar um pouco conforme a versão do painel.)
4. Abra **Project Settings** > **API**. Copie:
   - **Project URL**
   - **anon public** key (a chave que começa com `eyJ...`)
   **Nunca use a chave "service_role" no site.**
5. Abra o arquivo `config.js` desta pasta e troque os dois textos `COLE_AQUI...` pelos valores copiados. Salve.

## Parte 2: o site (GitHub)

1. Em **github.com**, clique em **New repository**. Nome: `paris-cast`. Deixe **Public**. Crie.
2. Clique em **uploading an existing file** (ou **Add file > Upload files**) e arraste **todos os arquivos desta pasta**: `index.html`, `backend.js`, `config.js`, `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png`. Clique em **Commit changes**.
3. Vá em **Settings** > **Pages**. Em **Source**, escolha **Deploy from a branch**, branch **main**, pasta **/ (root)**, e salve.
4. Em 1 a 2 minutos o endereço aparece no topo da página: `https://SEU-USUARIO.github.io/paris-cast/`. Esse é o link da rádio.
5. Volte no Supabase em **Authentication** > **URL Configuration** e coloque esse endereço em **Site URL**.

## Parte 3: primeiro acesso (você, o dono)

1. Abra o link da rádio **com `#dono` no final**: `https://SEU-USUARIO.github.io/paris-cast/#dono`
2. Toque em **Acesso do dono**, escreva um e-mail e uma senha e toque em **Criar conta de dono**. Só a primeira pessoa que fizer isso vira dona. Depois disso, ninguém mais consegue.
3. Faça seu cadastro (nome, sobrenome e telefone). Pronto: você tem o cargo Dono.
4. Para entrar de novo em outro aparelho: abra o link com `#dono` e toque em **Entrar**.

## Parte 4: lançar

- Mande o link (sem `#dono`) para os alunos. Cada pessoa se cadastra com nome e sobrenome e telefone.
- No celular, peça para abrirem no **Chrome** e tocarem em **⋮ > Instalar app** (ou **Adicionar à tela inicial**). Instalada, a rádio abre como um app e tem a melhor chance de continuar tocando com a tela apagada.
- Dê cargos pela aba **Ouvintes** (botão **Dar cargo**). Quando você dá **Dono** a alguém, ela passa a ter acesso total de verdade.

## O que muda em relação à versão do Claude

- Quem entra **não precisa de conta no Claude**.
- Os cadastros, músicas e grade da versão antiga **não vêm junto**: a rádio nova começa vazia.
- O aviso de "palpite do Claude" nas músicas não existe aqui; a busca na internet (iTunes) continua.
- Quem limpar os dados do navegador ou trocar de aparelho vira uma pessoa nova. Para ela voltar, o dono usa **Remover cadastro** na aba Ouvintes e ela se cadastra de novo.

## Limites do plano gratuito do Supabase (importante)

- O projeto **pausa depois de 7 dias sem ninguém usar**. É só abrir o painel do Supabase e clicar em **Restore** para voltar. Durante a rotina da escola isso não acontece.
- Armazenamento: 1 GB de áudio (cerca de 250 a 300 músicas) e 500 MB de banco.
- No máximo cerca de **200 pessoas conectadas ao mesmo tempo** com o tempo real. Se a escola tiver mais ouvintes ao vivo juntos, será preciso o plano Pro do Supabase.
- Cada arquivo de áudio: até 20 MB, em M4A, MP4 ou WebM.

## Segurança

- A chave `anon` é pública por natureza. Quem protege os dados são as regras do banco (arquivo `supabase.sql`): só o dono mexe em cargos e cadastros, só a equipe cadastra músicas e monta a grade, e os pedidos ficam cifrados (só a equipe lê).
- Guarde a senha do dono e a senha do banco. Faça uma cópia das músicas no seu computador.

## Atualizar o site depois

Quando eu fizer uma nova versão, você recebe um novo `index.html`. No GitHub, abra o arquivo `index.html`, clique no lápis (ou em **Add file > Upload files**) e envie o novo. Não mexa no `config.js`.
