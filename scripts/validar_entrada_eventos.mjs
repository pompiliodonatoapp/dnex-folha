#!/usr/bin/env node
// DNEX Folha — verificação do CONTRATO de entrada dos geradores de XML do eSocial.
//
// O que faz, sem rede e sem segredo:
//   1. Carrega contracts/esocial/entrada-evento.schema.json (cópia do dnex-contador, com origem e hash no
//      "$comment") e confere o hash: sem o "$comment", o arquivo tem de ter o mesmo sha256 do original.
//   2. Roda o cenário sintético tests/ci/entrada_eventos_sintetico.sql no Postgres local (via psql, com as
//      variáveis PG* do ambiente ou --psql "<comando>"), que chama as funções folha.esocial_entrada_*_v1
//      e imprime uma linha "@@RESULT@@<chave>@@<json>" por chamada. O cenário roda numa transação e desfaz.
//   3. Valida a "entrada" de cada resultado PRONTO contra o JSON Schema, e confere o formato dos resultados
//      que não são prontos (entrada nula, sem evento na fila, com o que falta ou o bloqueio).
//   4. Confere que as dez entradas (S-1000, S-1005, S-1010, S-1020, S-1200, S-1210, S-2200, S-1298, S-1299,
//      S-3000) tiveram ao menos um resultado pronto válido.
//
// Por que não usa o ajv: o repositório não tem lockfile nem cache de pacotes, e a verificação não pode
// depender de rede em execução. O validador abaixo é pequeno e ESTRITO: só entende as palavras-chave que o
// contrato usa e RECUSA qualquer outra (o contrato não passa em silêncio se mudar de forma). Ele se testa
// (--self-test): aceita entradas válidas do gerador e recusa mutações inválidas conhecidas. Em CI o
// comando completo é: node scripts/validar_entrada_eventos.mjs
//
// Uso:
//   node scripts/validar_entrada_eventos.mjs                      (cenário + validação)
//   node scripts/validar_entrada_eventos.mjs --self-test          (só o autoteste do validador)
//   node scripts/validar_entrada_eventos.mjs --psql "docker exec -i folha-entrada-pg psql -U postgres -d folha_dev"
//   node scripts/validar_entrada_eventos.mjs --saida resultados.jsonl   (guarda o que o banco devolveu)
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ARQ_SCHEMA = resolve(RAIZ, 'contracts/esocial/entrada-evento.schema.json');
const ARQ_SQL = resolve(RAIZ, 'tests/ci/entrada_eventos_sintetico.sql');
const SHA_ORIGEM = '0cdaa9a17533cb5e6b528bff8d5f01e386f221a9d03da1286fc060bd9e2957db';
const EVENTOS = ['S-1000', 'S-1005', 'S-1010', 'S-1020', 'S-1200', 'S-1210', 'S-2200', 'S-1298', 'S-1299', 'S-3000'];

// ---------------------------------------------------------------------------
// Validador de JSON Schema (subconjunto estrito do contrato)
// ---------------------------------------------------------------------------
const IGNORADAS = new Set(['$schema', '$id', '$comment', 'title', 'description']);
const SUPORTADAS = new Set([
  'type', 'const', 'enum', 'pattern', 'minLength', 'maxLength', 'minimum', 'maximum', 'minItems', 'maxItems',
  'items', 'properties', 'required', 'additionalProperties', 'allOf', 'anyOf',
]);

function tipoDe(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
  return typeof v; // string, boolean, object
}
function igual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

/** Valida `v` contra `s`; devolve a lista de erros (vazia = válido). `c` é o caminho, só para mensagem. */
export function validar(s, v, c = '$') {
  const erros = [];
  if (s === true) return erros;
  if (s === false || typeof s !== 'object' || s === null) {
    return [`${c}: schema inválido`];
  }
  for (const k of Object.keys(s)) {
    if (!IGNORADAS.has(k) && !SUPORTADAS.has(k)) {
      throw new Error(`palavra-chave de schema não suportada pelo validador estrito: "${k}" em ${c}`);
    }
  }
  const t = tipoDe(v);
  if ('type' in s) {
    const ok = s.type === t || (s.type === 'number' && t === 'integer');
    if (!ok) erros.push(`${c}: tipo ${t}, esperado ${s.type}`);
  }
  if ('const' in s && !igual(s.const, v)) erros.push(`${c}: esperado ${JSON.stringify(s.const)}, veio ${JSON.stringify(v)}`);
  if ('enum' in s && !s.enum.some((e) => igual(e, v))) erros.push(`${c}: fora do domínio ${JSON.stringify(s.enum)}`);
  if (t === 'string') {
    if ('pattern' in s && !new RegExp(s.pattern, 'u').test(v)) erros.push(`${c}: "${v}" não casa ${s.pattern}`);
    // O leiaute conta posições em caracteres: usa-se o comprimento em pontos de código.
    const n = [...v].length;
    if ('minLength' in s && n < s.minLength) erros.push(`${c}: menos de ${s.minLength} posições`);
    if ('maxLength' in s && n > s.maxLength) erros.push(`${c}: mais de ${s.maxLength} posições`);
  }
  if (t === 'number' || t === 'integer') {
    if ('minimum' in s && v < s.minimum) erros.push(`${c}: abaixo de ${s.minimum}`);
    if ('maximum' in s && v > s.maximum) erros.push(`${c}: acima de ${s.maximum}`);
  }
  if (t === 'array') {
    if ('minItems' in s && v.length < s.minItems) erros.push(`${c}: menos de ${s.minItems} itens`);
    if ('maxItems' in s && v.length > s.maxItems) erros.push(`${c}: mais de ${s.maxItems} itens`);
    if ('items' in s) v.forEach((x, i) => erros.push(...validar(s.items, x, `${c}[${i}]`)));
  }
  if (t === 'object') {
    for (const r of s.required ?? []) {
      if (!(r in v)) erros.push(`${c}.${r}: campo obrigatório ausente`);
    }
    const props = s.properties ?? {};
    for (const [k, sub] of Object.entries(props)) {
      if (k in v) erros.push(...validar(sub, v[k], `${c}.${k}`));
    }
    if (s.additionalProperties === false) {
      for (const k of Object.keys(v)) {
        if (!(k in props)) erros.push(`${c}.${k}: campo desconhecido (o schema é estrito)`);
      }
    } else if ('additionalProperties' in s) {
      throw new Error(`additionalProperties diferente de false não é suportado (${c})`);
    }
  }
  if ('allOf' in s) for (const sub of s.allOf) erros.push(...validar(sub, v, c));
  if ('anyOf' in s) {
    let melhor = null;
    let passou = false;
    for (const sub of s.anyOf) {
      const e = validar(sub, v, c);
      if (e.length === 0) { passou = true; break; }
      if (melhor === null || e.length < melhor.length) melhor = e;
    }
    // Reporta os erros do ramo mais próximo (o que menos errou), não a lista de todos os ramos.
    if (!passou) erros.push(...(melhor ?? [`${c}: nenhum ramo do anyOf`]));
  }
  return erros;
}

// ---------------------------------------------------------------------------
// Schema: carga e conferência do hash
// ---------------------------------------------------------------------------
export function carregarSchema(arquivo = ARQ_SCHEMA) {
  const bruto = readFileSync(arquivo, 'utf8');
  const obj = JSON.parse(bruto);
  if (typeof obj.$comment !== 'string' || !obj.$comment.includes(SHA_ORIGEM)) {
    throw new Error('o $comment do schema não traz o sha256 de origem esperado');
  }
  const { $comment, ...resto } = obj;
  const hash = createHash('sha256').update(JSON.stringify(resto, null, 2) + '\n', 'utf8').digest('hex');
  if (hash !== SHA_ORIGEM) {
    throw new Error(`o schema copiado diverge da origem: sha256 ${hash}, esperado ${SHA_ORIGEM}`);
  }
  return resto;
}

// ---------------------------------------------------------------------------
// Autoteste: entradas válidas do gerador e mutações inválidas conhecidas
// ---------------------------------------------------------------------------
function autoteste(schema) {
  const base = (evento, dados) => ({
    evento, ambiente: 2, emissao: { geradoEm: '2026-11-15T10:30:00', sequencial: 1 },
    empregador: { tpInsc: 1, nrInsc: '11222333' }, dados,
  });
  const s1200 = base('S-1200', {
    indApuracao: 1, perApur: '2026-10', trabalhador: { cpfTrab: '11144477735' },
    demonstrativos: [{
      ideDmDev: '202610-000123-M', codCateg: '101',
      estabelecimentos: [{
        tpInsc: 1, nrInsc: '11222333000181', codLotacao: 'LOT-SINT-01',
        remuneracoes: [{ matricula: '000123', itens: [{ codRubr: 'SALARIO', ideTabRubr: 'DNEX01', vrRubr: '3000.00', indApurIR: 0 }] }],
      }],
    }],
  });
  const s1210 = base('S-1210', {
    perApur: '2026-11', beneficiario: { cpfBenef: '11144477735' },
    pagamentos: [{ dtPgto: '2026-11-05', tpPgto: 1, perRef: '2026-10', ideDmDev: '202610-000123-M', vrLiq: '2715.25' }],
  });
  const mut = (o, f) => { const c = structuredClone(o); f(c); return c; };
  const casos = [
    ['S-1200 válido', s1200, true],
    ['S-1210 válido', s1210, true],
    ['campo desconhecido no envelope', mut(s1200, (o) => { o.extra = 1; }), false],
    ['campo desconhecido em dados', mut(s1200, (o) => { o.dados.totalLiquido = '1.00'; }), false],
    ['dinheiro como número JSON', mut(s1210, (o) => { o.dados.pagamentos[0].vrLiq = 2715.25; }), false],
    ['CPF com dez dígitos', mut(s1200, (o) => { o.dados.trabalhador.cpfTrab = '1114447773'; }), false],
    ['evento desconhecido', mut(s1200, (o) => { o.evento = 'S-9999'; }), false],
    ['ambiente 3', mut(s1200, (o) => { o.ambiente = 3; }), false],
    ['sem demonstrativo', mut(s1200, (o) => { o.dados.demonstrativos = []; }), false],
    ['perRef com dia', mut(s1210, (o) => { o.dados.pagamentos[0].perRef = '2026-10-01'; }), false],
    ['emissão sem horário', mut(s1200, (o) => { o.emissao.geradoEm = '2026-11-15'; }), false],
    ['matrícula de 31 posições', mut(s1200, (o) => { o.dados.demonstrativos[0].estabelecimentos[0].remuneracoes[0].matricula = '9'.repeat(31); }), false],
  ];
  let falhas = 0;
  for (const [nome, doc, esperado] of casos) {
    const e = validar(schema, doc);
    const ok = (e.length === 0) === esperado;
    console.log(`${ok ? 'ok    ' : 'FALHOU'} autoteste: ${nome}${ok || esperado ? '' : ''}`);
    if (!ok) { falhas += 1; console.log('        erros:', e.slice(0, 3)); }
  }
  // Palavra-chave desconhecida precisa estourar, não passar em silêncio.
  let estourou = false;
  try { validar({ type: 'string', format: 'date' }, 'x'); } catch { estourou = true; }
  console.log(`${estourou ? 'ok    ' : 'FALHOU'} autoteste: palavra-chave não suportada é recusada`);
  if (!estourou) falhas += 1;
  return falhas;
}

// ---------------------------------------------------------------------------
// Cenário no banco
// ---------------------------------------------------------------------------
function rodarCenario(psqlCmd) {
  const partes = psqlCmd.split(/\s+/).filter(Boolean);
  const [exe, ...args] = partes;
  const r = spawnSync(exe, [...args, '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1', '-f', '-'], {
    input: readFileSync(ARQ_SQL, 'utf8'),
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) throw new Error(`não foi possível executar "${exe}": ${r.error.message}`);
  if (r.status !== 0) {
    throw new Error(`psql terminou com ${r.status}\n${r.stderr}`);
  }
  const linhas = [];
  for (const l of r.stdout.split('\n')) {
    const m = /^@@RESULT@@([^@]+)@@(.*)$/.exec(l);
    if (m) linhas.push({ chave: m[1], texto: m[2] });
  }
  return linhas;
}

function principal() {
  const argv = process.argv.slice(2);
  const idx = (f) => argv.indexOf(f);
  const psql = idx('--psql') >= 0 ? argv[idx('--psql') + 1] : (process.env.PSQL_CMD ?? 'psql');
  const saida = idx('--saida') >= 0 ? argv[idx('--saida') + 1] : null;

  const schema = carregarSchema();
  console.log(`schema: ${ARQ_SCHEMA.replace(RAIZ, '.')} (sha256 de origem conferido: ${SHA_ORIGEM.slice(0, 12)}...)`);
  const falhasAuto = autoteste(schema);
  if (falhasAuto > 0) {
    console.error(`autoteste do validador falhou (${falhasAuto})`);
    return 1;
  }
  if (argv.includes('--self-test')) return 0;

  const linhas = rodarCenario(psql);
  if (linhas.length === 0) {
    console.error('o cenário não devolveu nenhum resultado (@@RESULT@@)');
    return 1;
  }
  if (saida) writeFileSync(saida, linhas.map((l) => `${l.chave}\t${l.texto}`).join('\n') + '\n', 'utf8');

  let falhas = 0;
  const prontos = new Map();
  for (const { chave, texto } of linhas) {
    let r;
    try { r = JSON.parse(texto); } catch (e) {
      console.error(`FALHOU ${chave}: o banco devolveu algo que não é JSON: ${texto.slice(0, 120)}`);
      falhas += 1;
      continue;
    }
    if (!['pronto', 'incompleto', 'bloqueado'].includes(r.estado)) {
      console.error(`FALHOU ${chave}: estado inesperado ${r.estado}`);
      falhas += 1;
      continue;
    }
    if (r.estado === 'pronto') {
      const erros = validar(schema, r.entrada);
      if (erros.length > 0) {
        console.error(`FALHOU ${chave} (${r.evento}): a entrada não cumpre o contrato do gerador`);
        for (const e of erros.slice(0, 8)) console.error(`   ${e}`);
        falhas += 1;
        continue;
      }
      if (r.entrada.evento !== r.evento) {
        console.error(`FALHOU ${chave}: o evento do envelope (${r.entrada.evento}) difere do resultado (${r.evento})`);
        falhas += 1;
        continue;
      }
      if (/(^|[^\w])(NaN|null)([^\w]|$)/.test(JSON.stringify(r.entrada.dados).replace(/"[^"]*"/g, '""'))) {
        console.error(`FALHOU ${chave}: a entrada tem null ou NaN em dados`);
        falhas += 1;
        continue;
      }
      prontos.set(r.evento, (prontos.get(r.evento) ?? 0) + 1);
      console.log(`ok     ${chave}: ${r.evento} pronto e válido no contrato (${(r.pendencias ?? []).length} pendência(s))`);
    } else {
      const ruim = r.entrada !== null || r.event_id !== null
        || (r.estado === 'incompleto' && !(Array.isArray(r.faltando) && r.faltando.length > 0))
        || (r.estado === 'bloqueado' && !(Array.isArray(r.bloqueios) && r.bloqueios.length > 0));
      if (ruim) {
        console.error(`FALHOU ${chave}: resultado ${r.estado} fora do formato (entrada nula, sem evento, com o que falta ou o bloqueio)`);
        falhas += 1;
      } else {
        console.log(`ok     ${chave}: ${r.estado}, sem entrada e sem evento (como deve ser)`);
      }
    }
  }
  for (const ev of EVENTOS) {
    if (!prontos.has(ev)) {
      console.error(`FALHOU: nenhuma entrada pronta de ${ev} no cenário`);
      falhas += 1;
    }
  }
  console.log(`resumo: ${linhas.length} resultado(s), ${[...prontos.values()].reduce((a, b) => a + b, 0)} pronto(s) validado(s) no contrato, ${falhas} falha(s)`);
  return falhas > 0 ? 1 : 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = principal();
  } catch (e) {
    console.error(`ERRO: ${e.message}`);
    process.exitCode = 1;
  }
}
