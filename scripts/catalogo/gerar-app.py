import json
import sys, subprocess, os
# Uso (na raiz do delibra-web):  python3 scripts/catalogo/gerar-app.py ../delibra-app
# Lê o catálogo do site e escreve o Catalogo.kt do app (o app mostra os mesmos ajustes que o site).
AQUI = os.path.dirname(os.path.abspath(__file__))
APP = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(AQUI, '..', '..', '..', 'delibra-app'))
saida = subprocess.run(['npx', 'tsx', os.path.join(AQUI, 'exportar.ts')], capture_output=True, text=True, check=True, cwd=os.path.join(AQUI, '..', '..')).stdout
d = json.loads(saida)
def k(s):
    if s is None: return 'null'
    return '"'+str(s).replace('\\','\\\\').replace('"','\\"').replace('$','\\$').replace('\n','\\n')+'"'
def num(v): return 'null' if v is None else repr(float(v))
L=['''package com.pwexpress.feature.gestor.data

/** Catálogo das configurações — GERADO do site (src/features/configuracoes/definicoes.ts). Não edite à mão. */
data class Area(val chave: String, val titulo: String, val descricao: String)

data class Grupo(val chave: String, val titulo: String, val descricao: String, val area: String = "")

data class Param(
    val chave: String, val grupo: String, val rotulo: String, val descricao: String, val descricaoDesligado: String?,
    /** numero | booleano | opcoes (números) | escolha (textos) | texto | multi (vários textos; padraoTxt separado por vírgula) */
    val tipo: String, val padraoBool: Boolean, val padraoNum: Double, val unidade: String?,
    val min: Double?, val max: Double?, val passo: Double, val opcoes: List<Pair<Double, String>>,
    val padraoTxt: String? = null, val opcoesTxt: List<Pair<String, String>> = emptyList(),
    /** Onde pode ter exceção: tipo, cliente, motoboy. */
    val escopos: List<String> = emptyList(), val soDev: Boolean = false, val exemplo: String? = null, val escondido: Boolean = false,
) {
    /** O padrão como texto, para comparar com o valor salvo ("só o que mudei"). */
    val padraoComoTexto: String get() = when (tipo) {
        "booleano" -> padraoBool.toString()
        "escolha", "texto", "multi" -> padraoTxt ?: ""
        else -> if (padraoNum % 1.0 == 0.0) padraoNum.toLong().toString() else padraoNum.toString()
    }
}

val AREAS_CONFIG = listOf(''']
for a in d['AREAS']: L.append(f'    Area({k(a["chave"])}, {k(a["titulo"])}, {k(a["descricao"])}),')
L.append(')\n\nval GRUPOS_CONFIG = listOf(')
for ch,g in d['GRUPOS'].items(): L.append(f'    Grupo({k(ch)}, {k(g["titulo"])}, {k(g["descricao"])}, {k(g["area"])}),')
L.append(')\n\nval PARAMETROS = listOf(')
for p in d['PARAMETROS']:
    t=p['tipo']; pad=p['padrao']
    pb='true' if pad is True else 'false'
    pn=num(pad) if isinstance(pad,(int,float)) and not isinstance(pad,bool) else '0.0'
    ops=p.get('opcoes') or []
    on='listOf('+', '.join(f'{num(o["valor"])} to {k(o["rotulo"])}' for o in ops if isinstance(o['valor'],(int,float)))+')'
    ot='listOf('+', '.join(f'{k(o["valor"])} to {k(o["rotulo"])}' for o in ops if isinstance(o['valor'],str))+')'
    ptxt=k(pad) if isinstance(pad,str) else (k(','.join(pad)) if isinstance(pad,list) else 'null')
    esc='listOf('+', '.join(k(e) for e in (p.get('escopos') or []))+')'
    L.append(f'    Param({k(p["chave"])}, {k(p["grupo"])}, {k(p["rotulo"])}, {k(p["descricao"])}, {k(p.get("descricaoDesligado"))}, {k(t)}, {pb}, {pn}, {k(p.get("unidade"))}, {num(p.get("min"))}, {num(p.get("max"))}, {num(p.get("passo",1))}, {on}, {ptxt}, {ot}, {esc}, {"true" if p.get("soDev") else "false"}, {k(p.get("exemplo"))}{", escondido = true" if p.get("escondido") else ""}),')
L.append(')\n')
open(os.path.join(APP, 'feature/gestor/src/main/java/com/pwexpress/feature/gestor/data/Catalogo.kt'),'w').write('\n'.join(L))
