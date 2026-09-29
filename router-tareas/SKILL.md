---
name: router-tareas
description: Reparte tareas de código ya definidas de un plan entre Claude, Codex (suscripción de ChatGPT) y GLM (z.ai Coding Plan), cada una en una copia de trabajo separada del repo, con Claude revisando siempre el resultado y sacando del reparto al motor que falle tres veces. También mide qué gasta tu límite semanal de Claude y trae una política de qué modelo de Claude usar en cada fase. Úsala cuando haya un plan con varias tareas de código concretas y comprobables y quieras ahorrar el límite de Claude, cuando el usuario diga "reparte las tareas", "pásaselo a Codex", "que lo haga GLM", "usa el router", "router de tareas", "apaga el router", "enciende el router", "segunda opinión de Codex", o cuando pregunte cómo combinar varias suscripciones de IA para programar o cómo no quedarse sin límite semanal. No la uses para tareas pequeñas, sensibles o que necesitan todo el contexto de la conversación.
---

# Router de tareas: Claude reparte, Codex y GLM ejecutan, Claude revisa

Tienes varias suscripciones de tarifa plana (Claude, ChatGPT, z.ai) y un plan con tareas ya
definidas. En vez de gastar todo el límite de Claude, Claude se queda lo que requiere criterio y
reparte lo acotado y lo mecánico. **Nunca se acepta un resultado sin que Claude lo revise.**

No hace falta tener sesiones abiertas con los otros modelos: arrancan bajo demanda, hacen la tarea
y terminan. Tenerlos abiertos a mano solo mezcla contextos entre tareas.

**Tres palabras que se usan mucho:** *motor* = un modelo externo a Claude que el script sabe lanzar
(Codex, GLM); *worktree* = copia de trabajo de git en otra carpeta y otra rama, donde el motor edita
sin tocar tu repo; *cupo* = el límite semanal de uso de tu plan de Claude.

**Qué hay en esta skill**

| Fichero | Para qué |
|---|---|
| `scripts/router.sh` | El programa: aísla la tarea, la lanza, apunta veredictos y mide el cupo |
| `scripts/cupo.py` | Calcula cuánto has usado de cada modelo de Claude (lo llama `router.sh cupo`) |
| `plantillas/tarea-atomica.md` | Formato obligatorio de cada tarea que se reparte |
| `plantillas/adversarial.md` | Instrucciones de la revisión «busca motivos para NO aceptar» |
| `referencias/politica-modelos.md` | Qué modelo de Claude usar en cada fase y qué hacer según el cupo (plantilla que editas) |
| `referencias/cupo-barra.md` | Cómo hacer que tu barra de estado apunte el cupo sola |

## 1. Quién hace qué

| Motor | Recibe | No recibe nunca |
|---|---|---|
| **Claude** | Planificar, arquitectura, seguridad, credenciales, producción, fallos sin causa clara, textos para clientes y **la revisión final de todo** | — |
| **Codex** (ChatGPT) | Implementación acotada con tests: una función, un endpoint, un refactor de pocos ficheros; segunda opinión dura sobre un cambio | Secretos; nada que toque producción |
| **GLM** (z.ai) | Mecánico en volumen: renombrados, código repetitivo, migrar formatos, tests sencillos, documentar código | Datos personales, salud, pagos o código sensible de clientes |

## 2. Cuándo NO se reparte

- **Si revisar, mandar y organizar va a costar más que hacerlo.** Tareas de menos de ~10 minutos
  o que necesitan todo el contexto de la conversación: las hace Claude directamente.
- Cambios que cruzan muchos ficheros o sin forma clara de comprobarse (sin tests ni criterio de
  aceptación verificable).
- Repos con ficheros sensibles trackeados (`.env`, claves): el script se niega solo.
- Datos que no deben salir a ese proveedor (ver §9).

## 3. La regla de las 3

Cada tarea termina con un **veredicto** de Claude: `ok` o `mal` con motivo. Es `mal` si la
calidad es peor que la que habría dado Claude, si hubo que rehacerla, si tocó tests para ponerlos
en verde o si dio más guerra de la que ahorró. **Tres `mal` en 30 días sacan al motor del reparto
automáticamente.** Solo vuelve cuando el usuario lo decide (`router.sh activar <motor>`), y al reactivarlo **la cuenta
empieza de cero**. Si el motor ni llegó a trabajar (se acabó su límite de uso, no arrancó), el
veredicto es `nulo`: no cuenta ni a favor ni en contra.
Se puede cambiar el 3 y los 30 con `ROUTER_STRIKES` y `ROUTER_VENTANA_DIAS`.

## 4. Interruptor general: apagar y encender

Si el usuario dice «apaga el router» (o quiere trabajar como antes, sin repartir), ejecuta
`router.sh apagar`: Codex y GLM no reciben nada (tampoco `revisar` ni `adversarial`) y Claude lo
hace todo. No borra datos ni registro. Para volver, `router.sh encender`. `router.sh estado` avisa
cuando está apagado.

## 5. La primera vez: pregunta qué suscripciones tiene

Antes de configurar nada, **pregunta al usuario** (una sola pregunta, con opciones):

> ¿Qué suscripciones tienes además de Claude? · ChatGPT (para usar Codex) · GLM Coding Plan de
> z.ai · las dos · ninguna

| Tiene | Configura con | Qué pasa |
|---|---|---|
| Las dos | `router.sh init codex,glm` | Reparto completo |
| Solo ChatGPT | `router.sh init codex` | Codex recibe también lo mecánico sencillo; lo sensible sigue en Claude |
| Solo GLM | `router.sh init glm` | GLM hace lo mecánico; la implementación con criterio la hace Claude |
| Ninguna | `router.sh init ninguno` | El router no reparte: todo lo hace Claude. Explícale qué ganaría con cada suscripción, sin insistir |

Después comprueba lo que necesita cada motor elegido (§8) antes de la primera tarea. Si más adelante
contrata una suscripción, basta `router.sh activar <motor>`. Si pregunta dónde se guarda todo:
`~/.router-tareas/` (cámbialo con `ROUTER_HOME`).

## 6. Cómo se reparte una tarea (paso a paso, lo ejecuta Claude)

```bash
R=<ruta de esta skill>/scripts/router.sh
$R estado                                  # qué motores están activos y cómo van
```

**Antes de repartir, divide.** Una tarea larga se rompe en tareas atómicas: una por fichero o por
función, de ~10 minutos, cada una con su criterio de aceptación.

1. **Escribe la tarea** copiando `plantillas/tarea-atomica.md` y rellenando todos los apartados:
   objetivo, 1-3 ficheros, criterios de aceptación **con al menos un caso límite** (sin eso, GLM
   resuelve los casos raros a medias), si es sensible, tipo (`mecanica`, `acotada`,
   `multi-fichero`, `dificil`) y tope de tiempo.
2. **Comprueba el formato:** `$R validar tarea.md`. `lanzar` hace la misma comprobación y se niega
   si falta algo.
3. **Elige el motor con la tabla de reglas** (`$R regla acotada`): mecánica → GLM (o Codex si no hay
   GLM), acotada y multi-fichero → Codex, difícil → Claude, sensible → Claude. Si usas otro distinto,
   `lanzar` avisa; anota por qué. La tabla vive en `~/.router-tareas/reglas.json` (cada tipo lleva
   una lista de motores por orden de preferencia) y se edita a mano.
4. **Lanza** en una copia de trabajo separada (git worktree, rama `router/<id>`):
   `$R lanzar codex <repo> <id> tarea.md 30` (el último número es el tope en minutos).
   **Reglas duras que el script no deja saltar:** tarea sensible → no sale; tipo difícil → no
   sale; GLM en una ruta de `ROUTER_NO_GLM` → no sale.
5. **Revisa tú** (Claude), sin fiarte de lo que diga el motor:
   - `git -C ~/.router-tareas/trabajos/<id>/wt diff --cached HEAD` y léelo entero;
   - comprueba que **no se ha tocado ningún test** existente;
   - pasa **tú** los tests del criterio de aceptación dentro del worktree;
   - piensa en los casos que los tests no cubren.
6. **Veredicto:** `$R veredicto <id> ok`, `$R veredicto <id> mal "motivo concreto"` o
   `$R veredicto <id> nulo "motivo"` (el motor no llegó a trabajar). Con `ok`, el script guarda los
   cambios como commit en la rama `router/<id>`.
7. Si es `ok`: `git -C <repo> merge router/<id>`. Si es `mal`: o se reintenta una vez con una
   tarea mejor escrita, o la hace Claude.
8. `$R limpiar <id>` (o `$R limpiar --forzar <id>` si la tarea se quedó a medias sin veredicto).
9. **Al terminar el reparto, presenta SIEMPRE la tabla:** `$R resumen`. Enseña, por cada tarea, qué
   se le mandó a qué motor, cuánto tardó y cómo salió tu revisión (bien / mal y por qué), más
   una línea con lo que hiciste tú directamente. Es la forma de que el usuario vea de un vistazo qué
   se delegó y si se hizo bien.

Puedes lanzar varias tareas independientes en paralelo (cada una en su worktree), pero revisa
y fusiona de una en una.

## 7. Segunda opinión antes de dar algo por bueno (Codex, sin permiso de escritura)

Además de repartir, Codex sirve de revisor independiente: otro fabricante ve fallos que el tuyo
no ve. Corre **sin permiso de escritura**: no puede cambiar nada en el repo. (Ojo: «sin escritura» no es «sin
lectura». Ver §9.)

```bash
$R revisar     <repo> [base|--sin-commit]   # revisor nativo de Codex sobre el diff
$R adversarial <repo> [base|--sin-commit]   # busca motivos para NO aceptar el cambio
```

El informe queda en `~/.router-tareas/trabajos/<comando>-<fecha>/informe.md`. **Claude lo lee y
decide qué hallazgos son reales**; ninguno se aplica sin comprobarlo. No sustituye a tu propia
revisión: va antes de ella.

## 8. Qué necesita cada motor (una vez)

- **Codex:** `npm i -g @openai/codex` y `codex login` con tu cuenta de ChatGPT.
- **GLM:** suscripción GLM Coding Plan en z.ai (el plan básico basta para trabajo mecánico) y la
  clave disponible como `ZAI_API_KEY`, o mejor mediante un comando que la saque de tu gestor de
  contraseñas: `export ROUTER_GLM_KEY_CMD='security find-generic-password -s zai -w'` (macOS) —
  así la clave nunca queda escrita en un fichero ni en el historial. Todavía más seguro, si tu gestor
  sabe lanzar un programa con un secreto inyectado: `ROUTER_GLM_WRAP='mi-gestor run zai --as ANTHROPIC_AUTH_TOKEN --'`;
  entonces la clave no pasa ni siquiera por el script, solo llega al proceso de GLM.
- Requisitos: `git`, `python3`, `perl` y Claude Code.

## 9. Datos y privacidad

- **ChatGPT/Codex:** desactiva en la configuración de datos de ChatGPT «Mejorar el modelo para
  todos» (y lo equivalente en Codex) si no quieres que se entrene con tu código.
- **z.ai (GLM):** es un proveedor fuera de la UE y de EE. UU.; lee su política de datos antes de
  usarlo. No le mandes datos personales de clientes, datos de salud o de pagos, ni código sensible.
  Para blindarlo por ruta: `export ROUTER_NO_GLM="/clientes/:/produccion/"` y GLM se negará a
  trabajar ahí.
- Nunca pongas secretos en la tarea. Si una tarea necesita una credencial, la hace Claude.

**Qué aísla el worktree y qué NO (léelo):**

| | Lo que sí hace | Lo que no hace |
|---|---|---|
| Cambios | El motor edita una copia en otra carpeta y otra rama; tu repo no cambia hasta que fusionas tú | — |
| Lectura | — | Un motor con acceso a tu disco puede **leer** ficheros fuera de la copia: el `.git` de la copia apunta a tu repo original, así que un `.env` sin trackear de tu repo es legible. **No hay aislamiento de lectura.** |
| Red | — | No se bloquea la red de las herramientas del motor |
| GLM | Corre con un `HOME` desechable (no ve tu `CLAUDE.md` global, tus MCP ni tus hooks), con la clave solo en su entorno, y con herramientas limitadas a leer/editar y ejecutar tests | Sigue siendo Claude Code sin sandbox de sistema operativo |
| Codex | Sin permiso de escritura fuera de la copia | Puede leer tu disco; lo que lea puede enviarse a OpenAI |

Si necesitas aislamiento de verdad (repos con secretos sin trackear, código de clientes), ejecuta el
router dentro de un contenedor o una máquina virtual, o no repartas esa tarea. Y **la revisión de
Claude es obligatoria**: lee el diff y pasa los tests él mismo antes de fusionar.

- El script se niega a repartir si hay ficheros sensibles **trackeados** (`.env`, claves `.pem`,
  `credentials.*`…).

## 10. Cuidar tu límite semanal de Claude (opcional)

Si tienes un plan con límite semanal, el router también sirve para saber qué lo gasta:

```bash
$R cupo 81      # apunta «llevo el 81 % de la semana» + reparto de uso por modelo
$R cupo         # sin número: lo lee de ROUTER_CUPO_FILE (lo escribe tu barra de estado)
$R informe      # tabla: % de cupo frente a % de uso en Opus y contexto medio por llamada
```

Guarda una fila por día (automatízalo con `cron` o `launchd` si quieres; ver
`referencias/cupo-barra.md`). Con unas semanas de datos se ve qué mueve de verdad tu límite:
el modelo de la sesión, el tamaño del contexto o la caché. **No asumas que cambiar de modelo lo
arregla:** mide.

Qué modelo usar en cada fase (planificar, descomponer, implementar, revisar) y qué hacer según el
% de cupo: `referencias/politica-modelos.md`. Es una plantilla; edítala con tus reglas.

## 11. Qué dice la experiencia

- En una prueba propia del autor, con una función y cuatro tests, **Codex** la resolvió limpia en 25 s. **GLM** también
  pasó los tests (81 s) pero con una solución peor en un caso que los tests no cubrían. Conclusión:
  con GLM, los casos límite tienen que ir escritos en los criterios de aceptación (y por eso la
  plantilla los exige).
- Cualquier modelo puede «arreglar» un fallo cambiando el test en vez del código, o seguir en
  silencio instrucciones contradictorias. Por eso la revisión es de Claude, siempre, y por eso se
  comprueba que los tests no se han tocado.
- En una revisión adversarial real del autor sobre un cambio ya revisado por otro modelo de Claude,
  Codex encontró 2 fallos menores reales que la revisión anterior no vio. Es una sola observación,
  no una estadística: mide con tu propio trabajo.
