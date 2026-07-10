# Como usar seu e-mail da empresa dentro do Gmail

Com este passo a passo você vai conseguir **ler e enviar** os e-mails do seu endereço da empresa
(`@polyenergia.com.br`) direto pela sua conta do **Gmail**, sem precisar abrir outro site.

## Antes de começar, tenha em mãos:

- **Seu endereço da empresa** (exemplo: `seu-nome@polyenergia.com.br`)
- **A senha desse e-mail** (a mesma que você usa no webmail; se não tiver, peça para o responsável de TI)
- Um computador com o **Gmail aberto** (é mais fácil fazer no computador do que no celular)

---

## Parte 1 — Receber seus e-mails da empresa no Gmail

1. No Gmail, clique na **engrenagem** ⚙️ (canto superior direito) e em **“Ver todas as configurações”**.
2. Clique na aba **“Contas e importação”**.
3. Na seção **“Verificar e-mail de outras contas”**, clique em **“Adicionar uma conta de e-mail”**.
4. Digite o seu endereço da empresa e clique em **“Próxima”**.
5. Escolha a opção **“Importar e-mails da minha outra conta (POP3)”** e clique em **“Próxima”**.
6. Preencha os campos exatamente assim:
   - **Nome de usuário:** seu endereço completo (ex.: `seu-nome@polyenergia.com.br`)
   - **Senha:** a senha do seu e-mail
   - **Servidor POP:** `mail.polyenergia.com.br`
   - **Porta:** `995`
   - ✅ Marque a opção **“Sempre usar uma conexão segura (SSL)…”**
   - (opcional) ✅ Marque **“Manter uma cópia da mensagem recuperada no servidor”** se quiser que os
     e-mails continuem também no webmail.
7. Clique em **“Adicionar conta”**.

Pronto — o Gmail vai começar a trazer seus e-mails da empresa (ele verifica de tempos em tempos).

---

## Parte 2 — Enviar e-mails com seu endereço da empresa

Assim você consegue, ao escrever um e-mail no Gmail, escolher enviar **como** `@polyenergia.com.br`.

8. Ainda em **“Contas e importação”**, na seção **“Enviar e-mail como”**, clique em
   **“Adicionar outro endereço de e-mail”**.
9. Coloque o **seu nome** (como quer aparecer) e o **seu endereço da empresa**.  Marque **"Tratar como um alias". Clique em
   **“Próxima etapa”**.**
10. **Preencha:- **Servidor SMTP:** `mail.polyenergia.com.br`

    - **Porta:** `465`
    - **Nome de usuário:** seu endereço completo
    - **Senha:** a senha do seu e-mail
    - Deixe marcado **“Conexão segura usando SSL”**

    **
11. **Clique em **“Adicionar conta”**.**
12. **O Gmail vai **enviar um email de verificação, abra o email e clique no link**.**

Pronto! Agora, ao escrever um e-mail novo, no campo **“De”** você pode escolher o seu endereço da
empresa.

---

## Dados do servidor (caso o Gmail peça)

| Para…                  | Servidor                    | Porta   | Segurança |
| ----------------------- | --------------------------- | ------- | ---------- |
| **Receber** (POP) | `mail.polyenergia.com.br` | `995` | SSL        |
| **Enviar** (SMTP) | `mail.polyenergia.com.br` | `465` | SSL        |

- **Usuário:** sempre o seu e-mail completo (ex.: `seu-nome@polyenergia.com.br`)
- **Senha:** a senha do seu e-mail

## Dúvidas comuns

- **“Não recebo o código de confirmação.”** Espere alguns minutos e confira também o webmail. O Gmail
  só busca e-mails de tempos em tempos, então pode demorar um pouco.
- **“Deu erro de senha.”** Confira se digitou o **endereço completo** no campo de usuário e a senha
  correta. Se persistir, peça ao TI para verificar/redefinir sua senha.
- **“Não sei minha senha.”** Fale com o responsável de TI — ele consegue redefinir para você.
