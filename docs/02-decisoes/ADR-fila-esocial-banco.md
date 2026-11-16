# ADR — Fila de eventos do eSocial no banco (catálogo, estados, lote, retorno, retificação, exclusão e plano de desfazer)

Data: 15/11/2026. Estado: **implementada na migration 0031, não aplicada em nenhum ambiente**; aceite do proprietário pendente. Fontes de requisito: parecer técnico eSocial/EFD-Reinf de 15/11/2026 (seções 3, 4.3 a 4.7 e 4.9), plano de construção da Folha ("Modelo de dados a adotar", "Diferenciais") e o levantamento de mercado de 15/11/2026, usado só como referência de requisito (estados da fila, "não entra em processamento é sempre antecessor não validado", reabertura e exclusão). Nomes, desenho e texto são próprios.

## Problema

A fila antiga (`folha.esocial_event_outbox`, 0018) só aceita nove códigos, exige `run_id`, tem cinco estados (`transmitido` mistura protocolo com aceitação), não tem recibo por evento, versão, retificação, exclusão, lote nem ocorrência, e a idempotência descarta em silêncio o evento corrigido. Nada impedia enfileirar S-1200 de folha aberta, nem enviar S-1299 antes dos periódicos aceitos. O erro mais caro dos sistemas de mercado é desfazer a cadeia na ordem errada.

## Decisão

1. **Catálogo e antecessores em tabelas** (`esocial_event_catalog`, `esocial_event_antecessor`): 28 códigos (tabelas, não periódicos, periódicos, SST, exclusão, totalizadores) e 37 regras de dependência, só com o que o parecer sustenta; o resto vai `a_validar` (8 códigos e 14 regras). A regra `a_validar` é aplicada, mas a mensagem de bloqueio a marca ("regra a validar"). Totalizadores S-5001/5002/5003/5011/5012/5013 estão no catálogo como retorno do governo e não se enfileiram. Sem seed por conta.
2. **Evento com chave de negócio calculada** pelo banco a partir do catálogo (parecer 4.7), **versão**, `origem_hash` (idempotência), `payload_hash` do XML gerado, recibo, `retifica_event_id` e `exclui_event_id`. Uma só versão aberta por chave (índice parcial). Idempotência: mesma origem não cria nada; origem diferente com versão ainda não enviada substitui (a anterior fica cancelada); em transmissão recusa; versão validada com origem diferente só pela retificação; nunca `DO NOTHING` silencioso.
3. **Máquina de estados em tabela** (`esocial_event_transition`, 18 transições; 13 estados) conferida por gatilho. Nenhuma transição pula estado; `retificado` e `excluido` só entram pelo retorno aceito da retificação ou do S-3000. Para `gerado`: XML guardado com hash calculado pelo banco, antecessores validados do mesmo empregador e ambiente, folha de origem fechada, período não fechado. Depois de `gerado`, o hash e a identidade do evento não mudam; o XML (gerado, assinado) e os retornos ficam em tabela só de anexar, nunca em auditoria ou mensagem de erro.
4. **Lote** (até 50 eventos, um empregador, um grupo; S-1299 em lote próprio), com situação conforme os códigos do parecer 4.3 (201/202 recebido, 301 erro do servidor reenviável, 401/402 lote incorreto não reenviável, sem resposta). Retorno por evento: validado (recibo, advertência opcional), rejeitado ou duplicado, com ocorrências (erro ou advertência) e retorno guardado inteiro. Reenvio vai em outro lote e conta a tentativa.
5. **Fechamento por ciclo.** O S-1299 e o S-1298 têm um ciclo (n-ésimo fechamento e n-ésima reabertura do período); a chave inclui o ciclo para fechar, reabrir e fechar de novo sem colisão. Período fechado = mais S-1299 validados que S-1298 validados. Em período fechado não entram, não se retificam nem se excluem eventos periódicos antes da reabertura.
6. **Retificação e exclusão** exigem o evento validado com recibo; a retificação herda a chave e as origens; a exclusão (S-3000) recusa evento com dependentes já enviados e período fechado. As duas exigem `folha.transmit` e `folha.close` (parecer 4.9: quem aprova é papel distinto de quem prepara) e motivo (aprovação registrada na auditoria).
7. **Folha**: evento de remuneração, pagamento, desligamento e fechamento só nasce de folha FECHADA, sem pendência aberta e do mesmo empregador (trava da 0027); conferido ao enfileirar e de novo ao gerar. Folha aberta, cancelada, com pendência, sem empregador ou de outro empregador é recusada.
8. **Produção** exige liberação explícita por empregador (`folha.admin`; parecer 4.2); conferida ao enfileirar e ao enviar o lote.
9. **Plano de desfazer** (`esocial_desfazer_plano_v1`, só leitura): por período ou por evento; reabertura do período fechado primeiro, depois dependentes antes dos antecessores (Kahn por rodada). Passos: `reabrir_periodo`, `excluir` (S-3000), `cancelar` (não enviado) e `aguardar_retorno` (em transmissão). Exigem decisão humana: a reabertura (DCTFWeb e FGTS Digital; parecer 4.6), o evento em transmissão e a exclusão de cadastro, vínculo ou SST; toda exclusão e reabertura leva aprovação registrada. O plano não executa nada.
10. **Conferência** (`v_esocial_conferencia`, `esocial_conferencia_v1`): por empregador, ambiente e período, pendentes, em transmissão, rejeitados e bloqueados por antecessor; diz se o período pode fechar.
11. **ACL/RLS** no padrão da 0028: dez funções `_v1` com EXECUTE só para `dnex_gestao_api`, REVOKE antes de GRANT, `search_path` terminando em `pg_temp`, FKs compostas com `account_id`, RLS forçada, só leitura para worker e data_owner, subject do contexto gravado por gatilho (nada informado entra).

## Divergências e limites

- **S-1260 e S-1270** foram pedidos, mas os insumos só citam o S-1260 numa lista de rejeições de terceiros e não citam o S-1270: ficaram de fora do catálogo (não inventar código nem chave). Entram quando houver fonte.
- **Catálogo de rejeições**: só a estrutura (vazio), como pedido; os códigos ficam para a fatia de validação preventiva.
- **Grupo do lote**: o lote usa o grupo do catálogo (tabelas, não periódicos, periódicos, SST, exclusão), mais estrito que os três grupos do manual (1, 2, 3); o mapeamento do S-3000, do S-1298 e de SST para os grupos do manual não está nos insumos (a validar).
- **S-1210 e perRef**: a dependência S-1200/S-2299 casa por trabalhador, não por `perRef`; o leiaute exige conferir o período de referência (a validar).
- **Matrícula do eSocial** e demais dados do leiaute não existem no modelo; esta migration não gera XML. O vínculo é o contrato (`contract_id`).
- **XML bem-formado e XSD**: o banco guarda o texto e calcula o hash; validar contra o XSD é do gerador (dnex-contador). Limite de 8 MiB por conteúdo é só de sanidade, não regra do leiaute.
- **Rotinas sem usuário** não têm contexto da Folha (bloqueio 6 da 0028): o consumidor que envia e consulta lote precisa de um subject. Enquanto não houver, o retorno do lote é registrado por sessão de usuário.
- **S-1298 só com o S-1299 do mesmo ciclo validado** é regra `a_validar` (vem do levantamento de mercado, não do parecer).

## Pontos em aberto (decisão do proprietário ou validação na fonte)

1. As 14 regras de antecessor e os 8 códigos `a_validar` (quais viram firmes depois de conferir no leiaute e no MOS vigentes).
2. Mapa dos grupos do manual (1, 2, 3) para o lote e regra de lote de SST e exclusão.
3. Se retificar e excluir devem exigir `folha.close` além de `folha.transmit` (decisão adotada pelo parecer 4.9; reversível).
4. Calendário de prazos por evento (o parecer descreve as regras; não foram implementadas aqui).
5. Totalizadores guardados e reconciliados com a folha (fatia seguinte): hoje só o catálogo os reconhece.
6. Fila para Reinf (fora do schema `folha`, fatia 7 do plano).
7. Integração com `dispatch_folha_completa` e com a fila antiga: esta migration não os altera; a ligação do despacho com a fila nova fica para a fatia do gerador.
8. Sem teste de concorrência real (dois enfileiramentos ou retornos simultâneos); a serialização usa trava consultiva por chave e índice parcial.
9. **Revisão independente (duas rodadas), pontos sem correção nesta migration:**
   - Cadeia rejeitada ou duplicada e abandonada continua bloqueando o S-1299 e dependentes (`todos_existentes`); falta função de abandono e de reconciliação (consulta que grava o recibo de um duplicado ou sem resposta) e o registro da consulta antes do reenvio (parecer 4.4 e 4.7).
   - O S-1299 não espera o S-2299 do período (o S-2299 não tem período na chave) nem confere que todo resultado da folha virou evento; a conciliação com S-5xxx é da fatia seguinte.
   - `esocial_origem_conferir` não confere `tipo_processo` (13º, rescisão) nem a completude das origens.
   - O retorno do governo é dado de confiança de quem tem `folha.transmit`: `retorno_xml` não é obrigatório e não há subject de integração separado nem aprovador do envio distinto; o XML assinado não é conferido contra o gerado.
   - O plano de desfazer avalia dependentes um a um (com dois S-1200 do mesmo trabalhador, o S-1210 pode ficar fora do plano); não alcança dependentes de outro período (S-1210 de pagamento em mês seguinte), não trata S-1299 não validado e é O(n²) (limitar o tamanho ou materializar arestas antes de usar em empregador grande). `falha_comunicacao` aparece como "aguardar retorno".
   - O S-3000 também é aceito para evento de tabela (S-1000 a S-1070), que o parecer trata por vigência (`iniValid`/`fimValid`); a dependência por código de tabela usado (S-1010/S-1005 específicos) é por empregador, não por código; não há coluna de operação de tabela.
   - `esocial_dependentes` pode devolver dependente por antecessor sem relação com o alvo (falso positivo que bloqueia exclusão); `esocial_bloqueio_antecessor` para worker/data_owner depende de contexto (fora do contexto, a contagem de bloqueados da visão é 0).
   - XML pode aparecer em `DETAIL`/`STATEMENT` de erro de banco: o consumidor deve usar parâmetros ligados e `log_parameter_max_length_on_error = 0`. Worker e data_owner leem os XMLs da conta (considerar retirar o SELECT).
   - `pode_fechar_periodicos` sem ambiente mistura produção e restrita; classificação da causa de rejeição, cifra em repouso e retenção, `indGuia` e bloqueio de doméstico/MEI/segurado especial (4.7, 4.8, 4.9) não estão nesta migration.
   - Os antecessores S-2205/S-2206/S-2230/S-2299 <- S-2200 e a origem de folha do S-2299 estão como `firme` com base na ordem de 3.2 item 2; se o proprietário quiser o mesmo critério dos S-1020/S-1010, passam a `a_validar`.
   - Enfileirar o S-1298 exige `folha.close` (como retificar e excluir); a permissão e o motivo da reabertura valem na criação, não no envio.

## Consequências

Nada vai a produção sem aceite, aplicação da 0031 e o gerador de XML. O `down.sql` recusa reversão com dado em qualquer tabela da fila.
