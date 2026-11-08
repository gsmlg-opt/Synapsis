import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
// Self-contained source qualification. Setup copies no product implementation.
// The archive and existing installed dependency closure are verified below.
const archive = process.env.SYNAPSIS_LOBSTER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz';
const dependencyRoot = resolve(process.env.SYNAPSIS_LOBSTER_NODE_MODULES ?? 'apps/synapsis_core/priv/workflow_schema/node_modules');
const ownedBase = resolve(process.env.SYNAPSIS_STATE_ORACLE_ROOT ?? tmpdir());
await fs.mkdir(ownedBase, { recursive: true });
const root = await fs.mkdtemp(join(ownedBase, 'synapsis-state-source-'));
after(async () => { await fs.rm(root, { recursive: true, force: true }); });
assert.equal(createHash('sha256').update(readFileSync(archive)).digest('hex'), 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1');
await fs.mkdir(join(root, 'upstream'));
execFileSync('tar', ['-xzf', resolve(archive), '-C', join(root, 'upstream')]);
await fs.symlink(dependencyRoot, join(root, 'upstream/package/node_modules'), 'dir');
const load = name => import(pathToFileURL(join(root, 'upstream/package/dist/src/' + name + '.js')).href);
const { stateGetCommand, stateSetCommand } = await load('commands/stdlib/state');
const { diffLastCommand } = await load('commands/stdlib/diff_last');
const { defaultStateDir, keyToPath, stableStringify, readStateJson, writeStateJson, withFileLock, diffAndStore } = await load('state/store');
const { markLlmItem, llmProvenanceOf } = await load('core/llm_accounting');
const fixtureRoot = join(root, 'fixtures');
const sourcePins = {
  "package/LICENSE": "0197dda80dd142fdcaa45eaa2b55ad1d2adeb16c1fac2d445bd1cbaf9a7251fb",
  "package/dist/src/abortable_process.js": "cd5c443ae8621492744ef3af9c4bccf0a86c74885f08446726a707f8289f9020",
  "package/dist/src/commands/stdlib/approve.js": "5fbbbe295861d4fcde74778fcdcec7658eb5cc91e140b3c4d728a2861be763d3",
  "package/dist/src/sdk/primitives/approve.js": "fbd35a52e0ef6589a644aaea12566e07dbaf9c73d03359c66b5466b4258b4fa1",
  "package/dist/src/commands/stdlib/ask.js": "9133cbe30bddd28d322d3017f428317a6f98ab2bd9f43992b9f74594e3af6537",
  "package/dist/src/state/atomic_file.js": "87870c3439c4c8da907ada7f9a7412d5f84cc52e5225bb0deeab19b416c7d3b5",
  "package/bin/clawd.invoke.js": "86e2fd5b222e008965daaae87452ccb24641265950f13ded500e19a3759677ba",
  "package/dist/src/cli.js": "3a9b351cb972516cbd394654c0af65a8fdaaf521db4f68699410ca324dce480c",
  "package/dist/src/command_tokens.js": "a8cd45e37b2348cc3f847c1b06b2e2959594f360e05521f3ae45f57966a495fa",
  "package/dist/src/commands/commands_list.js": "494da027a85c10ce69c1e912f16e47c6bdad5830d26471e0ae17a9775a65093a",
  "package/dist/src/core/cost_tracker.js": "46accaf7286286025e5d83797f39c6bd47f8712b06ba835532d5151cf071c268",
  "package/dist/src/commands/stdlib/dedupe.js": "44884031087e54b4c10210b615827ab4852d72dd203e61ff6ad792ce1ae85f4f",
  "package/dist/src/commands/stdlib/diff_last.js": "994dff9523c7566a959b58f9e37bdcd0c34e7287f4f12ab60eabbbc7ef4f43aa",
  "package/dist/src/sdk/primitives/diff.js": "c2ff687876ac83843abae70b0bb82f9c746fcb08b7cf6afb7c6ba423df39dedc",
  "package/dist/src/workflows/dry_run.js": "d2c7e38a3037b44e2ee6d2218e6d01a54141309cd43a7d4fc8d62b6da8115703",
  "package/dist/src/commands/stdlib/email_triage.js": "fce576c5fa28d80d275ce2b524c6cee74694c7b408597326a894488e7d345637",
  "package/dist/src/commands/stdlib/exec.js": "8e5fa4cf5f868d848e3a3913f2b88ec9801edffa7498580c68b9c6cc8578dde7",
  "package/dist/src/sdk/primitives/exec.js": "54cdd43c3221fa772001791e808e4b551360b4f82588a24740689bca5f7ebf3e",
  "package/dist/src/workflows/expressions.js": "43712e54249604e7d2b149f27b7d460570dcee896f632c6d02f2855b16239551",
  "package/dist/src/workflows/file.js": "3d28c28aaa95124bd6b6136eb5bb2301ecf6570ee701ef46b0e606a22e01cdb8",
  "package/dist/src/core/filters.js": "d7d2fa2481fd302ba699394bc7e8db0dd86f9844a8b399e2aa4d4cd0aedb0c14",
  "package/dist/src/workflows/github_pr_monitor.js": "2e5b06ef6ae6a0d251e2cca5ead4a7d95aa4a1e198c04a554b2560b34d3540c0",
  "package/dist/src/commands/stdlib/gog_gmail_search.js": "6a88d413a3db8e0bb42251021ffffe0fea84710600a0c1e4a4326ec2feb7b19f",
  "package/dist/src/commands/stdlib/gog_gmail_send.js": "6cfaf626430220497af7b7c0dd95d82d5613b4af0243555546c6e8d6802de284",
  "package/dist/src/workflows/graph.js": "8e20ede0e5c5b0c0cf327b0b9135dba7972e2cca487021c8652471e6c550a0e1",
  "package/dist/src/commands/stdlib/group_by.js": "60befdc46480c45bf0d1c869a603780348fcf0b62b66a5cc34e4ef860d106cdc",
  "package/dist/src/commands/stdlib/head.js": "3045374b51c27c675ac529982d5f37aebb81fd15da94e41a329cdf2992650aa1",
  "package/dist/src/core/index.js": "adf16eb381e4cd2e1c2150cc567616ee57a6ce7d355622ac7d63a18a1997dcbc",
  "package/dist/src/recipes/github/index.js": "f02f26e1b1e9ac12c94051e91dae57691ff57243da79580e8472e8e1c8aced18",
  "package/dist/src/recipes/index.js": "f0c9b3841cbce26bdf0f5c23324a03dbb9ee4162bcc7c5c74f5bbc0b7bad6a1d",
  "package/dist/src/sdk/index.js": "f43d38055b5d747d4e9c756ce1ee166a0c62d00de121c7cb3f4d777405a8bec3",
  "package/dist/src/input_request.js": "4ee71a924f205641da2ea138a352ebe81ade206f90f7d666c66f6abea3e9aaa4",
  "package/bin/invoke.js": "a8d47f6c9d46358743245573bc3ec3d868d81ef51f6ae5f19e921d9b5ef486ea",
  "package/dist/src/commands/stdlib/json.js": "9e3f24e0a2bcba55e466f300901fd0f0b2d079fa075a55ee296c54201df76b58",
  "package/dist/src/renderers/json.js": "1a739a179aacb410add5fe954aec53e05fc89434b8e0aa8d8718b69fabfce681",
  "package/dist/src/core/llm_accounting.js": "c4c3278fdcdd991d12467a961a1c40e45d27dfd10c2fd630d64cfa31351b97cd",
  "package/dist/src/commands/stdlib/llm_invoke.js": "a77781c1ed2602feb368f8d5218d396b3726ac088fd3bd00689c1c5ef46d6421",
  "package/dist/src/commands/stdlib/llm_task_invoke.js": "5b0e665a0f7cd8a08debeef0f683a4116cfd77e15f6e3ba37329f8b9e0a249d9",
  "package/dist/src/workflows/load.js": "c7ae1c44997548b099860dadc482d88ba3c1d14a5fa58ee0b248e5054b990d6b",
  "package/bin/lobster.js": "081ba22819b4803c282fb569eb4c085ea8de501fa38e1a0b4c6572b2ca78e73d",
  "package/dist/src/sdk/Lobster.js": "b30afc9970386db0deb08dd50754e262e3ec2883d2186dab662c302084483596",
  "package/dist/src/commands/stdlib/map.js": "faeebf18c5db3903ae5e03270b87f49e5a1b8a5324276add6ca52c83763d8e27",
  "package/dist/src/commands/stdlib/openclaw_agent.js": "c6cec9d0bd1f696493bc42aebc7a99e1ff3dcd5560a9fd8710d1c1368c14731c",
  "package/dist/src/commands/stdlib/openclaw_invoke.js": "8f30e8f834446dbdb527f96dcf9b86caf8392139c0f96f3d9aac864d1705dd71",
  "package/bin/openclaw.invoke.js": "0d14f070e7951b526913cc61fe3ace9e75e159ccd0ceaaede8e2b91646d45ddc",
  "package/dist/src/parser.js": "e8f3f5cc67b1739b7347da70ea9a543d68f8e5f622387910d0202bb0f5b030ce",
  "package/dist/src/commands/stdlib/pick.js": "3d224840f187aa86c8414873f3782827e80e0ef9e176c085ceb2bb05f12d402c",
  "package/dist/src/pipeline_resume_state.js": "6dc84d6e015623b7d2023b85ebd6723077bee655ef4b47def82cd0813198c358",
  "package/dist/src/recipes/github/pr-monitor.js": "c9368fa8471dbe223d43f4bb3a39ddba72289b9a810c3a84b79731e0b3a436da",
  "package/dist/src/recipes/github/stages/pr-view.js": "db16e9f4b350ac0ad8b9b5512dba11d94f9de4a17195d7c383e8475a70fe4513",
  "package/dist/src/read_line.js": "8713afd728f1dd0400d002bdcea3df8b4cb99ebe3278eb4544b0fddbd0999904",
  "package/dist/src/recipes/github/read_pr.js": "dd3e2162e108a6b65343a2a059881042c3af3acc7ee65a52a5740c6395e3624c",
  "package/dist/src/read_response_text.js": "7afd34f45b0b0f6c94fb291b7d6a7a3a006e420e2771f8c526d9323d0f529c9a",
  "package/dist/src/commands/registry.js": "39661a446f4ed59174eb3a213fe6331555901163ab40485d01e0c841181c2fdd",
  "package/dist/src/recipes/registry.js": "b166c461eb88dcdeb020cedfdf445323e160b6bfc86293b8c15c15849ffd1807",
  "package/dist/src/workflows/registry.js": "a1406428c58a82c990d9c67738df7b4ab7925a0df18ec05cd84f42f6c5486681",
  "package/dist/src/resume.js": "29df3f0d8926c2109f783efd0ced591cb16beb913ec177ea4aa2d8a8ababc26f",
  "package/dist/src/core/retry.js": "a704b2a5f49330c000e0f92f8001942c271b5fa243b729cc2200b82803ed7790",
  "package/dist/src/runtime.js": "7cff8ff2120145f8f8155d7904efe04dc018bfe281725a76a677c7a885fcfd53",
  "package/dist/src/sdk/runtime.js": "4c05fe02aa2f371b2e7c3900b1d9fc826eecbd6f8cf5d268dfec69c7a664388d",
  "package/dist/src/shell.js": "7a0ee7c9f36955c6bad6b39e68c486d2e839734cee96c6110c3aa85dc0901b02",
  "package/dist/src/recipes/github/snapshot.js": "f92b2b0c31f23292c8e1f88d78fe134d85a0840736392a120d15d4c3539c1f38",
  "package/dist/src/commands/stdlib/sort.js": "a3d7fca0d780ebaac95e461703f27a8b4623ce40ac6f9e8e5d0d5eea5665d90f",
  "package/dist/src/sdk/state_env.js": "6564f82e253590a764ff0264cd2cd243ef1a964d1fe49e7a4be47a6820b3d2f9",
  "package/dist/src/commands/stdlib/state.js": "b71f910eb4106170e6509f6da108c6685368188d13f99c0c1435a53bce96628d",
  "package/dist/src/sdk/primitives/state.js": "303ac1dd13149ad6d07d310321df476b087cbb821c09a27211ab1fed9b78eff1",
  "package/dist/src/state/store.js": "8a0e750ccbf3e44135e96d82f4836d474369e8401feb8b498a77165afa29e77c",
  "package/dist/src/commands/stdlib/table.js": "a95a58ca8153f97596e7bf5eb1236e25c0ebdd0ddbf416fadcf2a4f4d07dd13e",
  "package/dist/src/commands/stdlib/template.js": "27ea3ef6d273a003d089b7c38ced0bd89233ee9615149e48ee732d0615b1d5ac",
  "package/dist/src/token.js": "02a6460b7f269c92e9d8ee9df952cc1445ef4fce1f9a508e1f60ef40fcb995e6",
  "package/dist/src/core/tool_runtime.js": "ba111a8b8ab28d1558910b32cddcfcde3139826dbdeb62aecfd6df03504ce4bc",
  "package/dist/src/commands/types.js": "01ae2a5b120382f9a648ced7ee8507493a134f216d100fc61600c6c9738235d2",
  "package/dist/src/workflows/types.js": "01ae2a5b120382f9a648ced7ee8507493a134f216d100fc61600c6c9738235d2",
  "package/dist/src/validation.js": "a9e087f2b5502be86dc223f2746c1d598446d4c1b5537f697003418417933f6b",
  "package/dist/src/core/value_path.js": "e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f",
  "package/dist/src/workflows/values.js": "4cc559281ee754d6a2aaa82bc5a6a10385adb3dc02eed62426e2534d765bc432",
  "package/dist/src/commands/stdlib/where.js": "0fdca14cfbf13abaadfc1fbb1bd44ce5d1fb2ccee04cb60c93120f52a944f8cc",
  "package/dist/src/commands/workflows/workflows_list.js": "2462c70155a7489a9f78ee9258ed01e272acdc0c57cfc4254722546f59b7f935",
  "package/dist/src/commands/workflows/workflows_run.js": "5a4a5d9a78fae2d8092415aa7cad247b71d80b41645d2dc54e6d2a9eaf65f281",
  "package/package.json": "8ec4aaa1901574565cd1407720185faa4c41e1400f926b726d777a253bfcb13d",
  "package/dist/src/abortable_process.js.map": "c8fe433069d0d28802dcbe2ae44a3f46ece396ed31526cd0ed7f606ae6759697",
  "package/dist/src/commands/stdlib/approve.js.map": "b8bb62f915d42e32becd9a3574acc4ec53986cc029300fd729606033bb2cff1c",
  "package/dist/src/sdk/primitives/approve.js.map": "922a6165955f12b70317d8bdad37cfc08e5fd129ec62ad34396da878d33c5d15",
  "package/dist/src/commands/stdlib/ask.js.map": "5fc20090038c98604021a117fa930b029563266b6cafc1f9d86ead71cfd748e6",
  "package/dist/src/state/atomic_file.js.map": "fe5579276506f9a7603da6ec73a3dfecd441d5a0db255dc89e228ebe2bb787fc",
  "package/dist/src/cli.js.map": "1d4e3933bbf097b53e3f674fa962213bb3bee63c257388931d7686250c481f76",
  "package/dist/src/command_tokens.js.map": "4b0ef898c5d50b4d4fbae4b72f385fb67752d5dca3d3cf8dcf70f7cbce9db8ee",
  "package/dist/src/commands/commands_list.js.map": "3c6220e775cb088c4fe8df6670368d4a97350f794fb30a36df8062ec4f53907b",
  "package/dist/src/core/cost_tracker.js.map": "65541f1be877c7d9c42b4fc08876278d3f8ae3fc9d3817e9edf2e6b93f224545",
  "package/dist/src/commands/stdlib/dedupe.js.map": "7ea25944ef9cd88e74bb480e38c28e408ac7c2700d6c8350433e2a68f7c8fe3e",
  "package/dist/src/commands/stdlib/diff_last.js.map": "bb95e5b442ce5cb5d0d6fd3a162567db9f71bd5c588f76029efa84afc17feae0",
  "package/dist/src/sdk/primitives/diff.js.map": "5115eb598de6155b73f099189d5a6c1746f93bb4327e058b6f0d909b0ad8594b",
  "package/dist/src/workflows/dry_run.js.map": "a3fb29123016228f4cb4aeb452c19c3812e24c1e0eda532776af6cb270092a65",
  "package/dist/src/commands/stdlib/email_triage.js.map": "06a29d892ff1c32778e899b02f3fd1fd22fcfd72a617313845f497b16c5a6d1a",
  "package/dist/src/commands/stdlib/exec.js.map": "8d04085080ad687031af1d67509e58f5a48ca274f035e34f8062a24726bc84a2",
  "package/dist/src/sdk/primitives/exec.js.map": "4c0dc4d2717844d4de7babed1836a989d412e03bf29fbefbc097744ad6713022",
  "package/dist/src/workflows/expressions.js.map": "d73973492fa66faf6c152617d9d9f0b8035ead7d4afa14aeb2e9eeb319a5638c",
  "package/dist/src/workflows/file.js.map": "e3282cf42704d85082e936b7e61a400f6ce15b0ca15a98754f9b0deea29527e5",
  "package/dist/src/core/filters.js.map": "c3cdba2f22954e4e03bc0f195a3efbe462d138204e2474edac3dba64a06d78dd",
  "package/dist/src/workflows/github_pr_monitor.js.map": "88cb71ceb2c70c141b50532787bd888d6ae65dc113a47fc71cf413ad6b9d471a",
  "package/dist/src/commands/stdlib/gog_gmail_search.js.map": "8a28a278d58d52ecf42fc71014d9c995df7912869abb98ee465cd4a19c775b05",
  "package/dist/src/commands/stdlib/gog_gmail_send.js.map": "5212eed371ac5c74b3d67747530a8dd5a21ed0351bcbf927cb0f46163a134697",
  "package/dist/src/workflows/graph.js.map": "93e1bdb2a7a27390c3ed1fd89392ca28b4ebdb19f4524853e3cd37e19cc9dc85",
  "package/dist/src/commands/stdlib/group_by.js.map": "679b46663cf977075ee88e3dc958226384fe5b5822dc30c39e931f5b2899b99d",
  "package/dist/src/commands/stdlib/head.js.map": "4be0f8315092366e0be497eb99cc19695d83e36e5dd613f95f7e03cce9e328e5",
  "package/dist/src/core/index.js.map": "ee3f9b42ac98c6a9211cd0b56ca927b93b13cbf42ffb371798c551d90249d1df",
  "package/dist/src/recipes/github/index.js.map": "dec90be6ae7a849fcebab089940dcaa132ec6070b790028eba26acea8a971a32",
  "package/dist/src/recipes/index.js.map": "8880af5c343abe3fd2b41b61c727b55c6ce16267f1b193c8b1768c14de92c3b5",
  "package/dist/src/sdk/index.js.map": "29811be7be1428e9c4c91e6c36d8accdaa13f50de9815bd3cfd77288b69a55a1",
  "package/dist/src/input_request.js.map": "5ea1af3f943d72cf85fd1ae53d14a2549510f3cca98da7e2732b64cc70d229c1",
  "package/dist/src/commands/stdlib/json.js.map": "7eab7f738ae12d9184ba38144d934d4bf3fadb5ad6c302236917525ec2fc7db4",
  "package/dist/src/renderers/json.js.map": "c64db1a6290face3c32d738dac85b7e90ea5390ff267eab16a959ba28a63e6e3",
  "package/dist/src/core/llm_accounting.js.map": "ef81e640a312ca46e76dec5ef65e9b21fa1407e7aec71047e79db1c7baf34c2e",
  "package/dist/src/commands/stdlib/llm_invoke.js.map": "2c74b97fda17aad9b86da7b465374a0d6c4b74e1a131402ffc93f94322b376a4",
  "package/dist/src/commands/stdlib/llm_task_invoke.js.map": "8b29ab8bfdacef67d70c7dad2fa95626d0becaa4f0003bd5966c40dbf992905d",
  "package/dist/src/workflows/load.js.map": "89c6decb588cb8992ac01364d9bcc5fc2c41b328a7922829030fac724f6acf0e",
  "package/dist/src/sdk/Lobster.js.map": "df2112fe789c8d5e4bf8d3b7738e2d601b6f32f548d5b84ca707819e23aba67e",
  "package/dist/src/commands/stdlib/map.js.map": "acbc46f8a181b3f3e8a086deaac1a5783f7d5d91ef8f5f94b436e120dad96db4",
  "package/dist/src/commands/stdlib/openclaw_agent.js.map": "bd653be4ff32db854532735c253d09e965c8a777480aa038c160bcc7addc8233",
  "package/dist/src/commands/stdlib/openclaw_invoke.js.map": "5174b52c1198d1bcbf777b9e239cc1232d8dfc0d93b6d7a5ab52ab1a3cc589e4",
  "package/dist/src/parser.js.map": "e115fee4a3dc316554f463f20d98c327e39c589e17d6e0f9bc1b5b60ea2a29c1",
  "package/dist/src/commands/stdlib/pick.js.map": "8b505d1d8967e783104966df0addcb20a6528371f10b0922a851a07b88a6cb3f",
  "package/dist/src/pipeline_resume_state.js.map": "95fa2136c829bed493a41621cfdc5d53c6f119c282a47a9756f89e2c8aef73c2",
  "package/dist/src/recipes/github/pr-monitor.js.map": "13094a87b1a6ed1dc4605f2369eda7cad234812d1ffdb03b62ff6a3dc569792f",
  "package/dist/src/recipes/github/stages/pr-view.js.map": "6418f10522ac30fd29a112e3ba4d2b7059804faa2c45778dd1ebeade94b4d934",
  "package/dist/src/read_line.js.map": "034d3e6bca7cd1d470cb9d68f70174bfe273c1577fc5abb8ab449c3efbf44cab",
  "package/dist/src/recipes/github/read_pr.js.map": "0e69b9d3e6bc0a4d286b0171636c787508c1317ae17a14dbfad1dc285bfb69eb",
  "package/dist/src/read_response_text.js.map": "2700dfb37bf28ed85428a1185c087e282ce271e0fcf73e03385be2e078745697",
  "package/dist/src/commands/registry.js.map": "a0846f07516ab9d24ee2b91a5b75bf42c05caf53a88ca9b31846c2294c1140ab",
  "package/dist/src/recipes/registry.js.map": "90c65e75077a43c5cb5cb0a7a2a1b826e1713d1f18a38358e6650ec482ab4d78",
  "package/dist/src/workflows/registry.js.map": "63dc477704ebe02ba523f029aee962521a1cef7c92575abe03c97b61dc51e7b6",
  "package/dist/src/resume.js.map": "1863ea2f12cec5fcc62f5862d366f3ef492f8b8db04f638262f374538339cb17",
  "package/dist/src/core/retry.js.map": "7297799843e5a1d6a1f957f4c5d61d13260490c62ccb7aa1eecfd25f36d30ea6",
  "package/dist/src/runtime.js.map": "1450e9916794259fde41c3c508cfde420429cf5533a917da18ea921c83912d4c",
  "package/dist/src/sdk/runtime.js.map": "0117378d34d4ab57d6b7280df841761ad6140a0a3a7ee60da73eb1699bf36856",
  "package/dist/src/shell.js.map": "45692cfa9dbb8ac1a1b04da44f4e16b38d0e540a5da116e3285460703263c730",
  "package/dist/src/recipes/github/snapshot.js.map": "b55e1619f8a941eee89cd18a7a035adc509ecac70e85c2db9cb274ed44db574d",
  "package/dist/src/commands/stdlib/sort.js.map": "706bde93aea5b5bf9fd22d27f38f6c01e11b62a4c0f1521124785a9a1f007587",
  "package/dist/src/sdk/state_env.js.map": "a30dd6ac04327733a8082d90869a1c191553a6c9618fc4674edb62d520cd846c",
  "package/dist/src/commands/stdlib/state.js.map": "5eaf2dbaf647449788cd9c75cd987bc7b01ba3b64a0880b1d034610f26add49c",
  "package/dist/src/sdk/primitives/state.js.map": "2e7359b49f00f2977894c429a72927fc0b81386f124f57fe3adc7ead0e6fd961",
  "package/dist/src/state/store.js.map": "2ed484ce43b9fb65fdace720e31abcd7210f1dbc041ed02c1b25b21e95fd15b7",
  "package/dist/src/commands/stdlib/table.js.map": "6732edbe406fd8371e788f6de1e2c0ab07b34946870485b2ddfdfc06275bf940",
  "package/dist/src/commands/stdlib/template.js.map": "d34898fd8494a6ae3c9cbbb9ec2093a928eab852b15aef30e3cbd5804abd7656",
  "package/dist/src/token.js.map": "0cc152cb4cfe8484fec15aef8a3de367a1774abe0b1185bf9aa29876c9cedbbd",
  "package/dist/src/core/tool_runtime.js.map": "c42a4ebde6235b863261ac60e2e240a2f5f3e2d71e127defa3aab256adf698d4",
  "package/dist/src/commands/types.js.map": "832ceb4cc2746443befa1d1cb62839f6f5e53deb524fdbe0fed41de3f9aa74a0",
  "package/dist/src/workflows/types.js.map": "5a12c322b117aebc29fe34a67bbd07ce5343e01cde22939962fbe4575b5548fa",
  "package/dist/src/validation.js.map": "0dd4fe2ea2fb0dd90c5025ab1c1d0250a11dd8db592c9f89a733da59071323cf",
  "package/dist/src/core/value_path.js.map": "c25177102d3daf8b4d1e0c0e0f362655908bdf08afbed7cd3fca19e87aeac146",
  "package/dist/src/workflows/values.js.map": "eb99b2920c1e327b86ad16bbaeee89ccb886f10313f59ceb3d913553b92fd174",
  "package/dist/src/commands/stdlib/where.js.map": "ba9e699793b338b588ad0138a2649b44c60b8c636f178e0d7e5c884a36889c85",
  "package/dist/src/commands/workflows/workflows_list.js.map": "5bfa368ff9f867694f2e4af6243c8c2e3f1f67c85727608aacf4007e6568b57e",
  "package/dist/src/commands/workflows/workflows_run.js.map": "8d52f3716532bc7ca4c9c68dc5ea3b4dac157e3afd0e7139c35a36f4b6f18572",
  "package/README.md": "ffbaaad4abef47a67b8a1ecab169d0bfb6748b7db9ad25c6a6539ad19c4a019e",
  "package/VISION.md": "8fcaa7e8d838c804dca4a9fa80eca216a85a456f3f033e97acf6ef3bf2ed0d30"
};
const dependencyPins = {
  "ajv/.runkit_example.js": "e37e85bf1db5d53a6e4e38a9cac83db25208f28c09a2fa19e3971877c8a7b8cf",
  "ajv/LICENSE": "a05350a88e318e4f5f2c2a1ff1e2e88daa4dd38e6e78b71cccae422bdc762cc3",
  "ajv/README.md": "38d924524762b917dd9dd341ac28837df51a474bf198ac4c26ba69d8f59a27c3",
  "ajv/dist/2019.d.ts": "1e2bbd6318653c49684963a59066e621a3a142ad23b5e809e430e73946aa4223",
  "ajv/dist/2019.js": "4a1b1d479d0b946af0119f3a3960fcabfd964e1c20e87f7a9575f8f9e705d0c4",
  "ajv/dist/2019.js.map": "a91b0607c55ef90f269dbefb567c975cfae953341c13761c43b7f8b78e44b91f",
  "ajv/dist/2020.d.ts": "66a5ace456d19768103c1da9df2abafa9cb2e78ff61c938746527ec2524e5d11",
  "ajv/dist/2020.js": "908e9670b478b2ba126802a221b7e47006f50cf467e2c5dd7935d3dbef10a20a",
  "ajv/dist/2020.js.map": "845f8c979380377abe0db2a8a8ba9c5484d88cc69dc6704db84c6fc176b330d5",
  "ajv/dist/ajv.d.ts": "41b8775befd7ded7245a627e9f4de6110236688ce4c124d2d40c37bc1a3bfe05",
  "ajv/dist/ajv.js": "edaed56fc546f5551b0d6dc2ff2a9cc25c2d6c83318a086eaa8c3ad0b2479297",
  "ajv/dist/ajv.js.map": "f6a0d17a5cdb4891ab056a48c852cc6dbb5e5ef262e3fccfc9021782d3714d44",
  "ajv/dist/compile/codegen/code.d.ts": "2d225e7bda2871c066a7079c88174340950fb604f624f2586d3ea27bb9e5f4ff",
  "ajv/dist/compile/codegen/code.js": "1287153722f1fc3c5342647de7ae1d7b6fb68bdb3378a0776a937d273fc97e0d",
  "ajv/dist/compile/codegen/code.js.map": "6662bc0c87dfefa43cabfe916340b03c128e6b4ffe8d08d162231a337299fe60",
  "ajv/dist/compile/codegen/index.d.ts": "c1422d016f7df2ccd3594c06f2923199acd09898f2c42f50ea8159f1f856f618",
  "ajv/dist/compile/codegen/index.js": "f03b2b72597ef86878d1d4030580c2d0964046efad4867f3d05aa91065ba034c",
  "ajv/dist/compile/codegen/index.js.map": "081d235ee23ad618f56c6bbda22b646522cba1b20534711fddfdbcb2b075affc",
  "ajv/dist/compile/codegen/scope.d.ts": "6a785f84e63234035e511817dd48ada756d984dd8f9344e56eb8b2bdcd8fd001",
  "ajv/dist/compile/codegen/scope.js": "d2a0a97af2faa2cad88702314fe421e235ab17f11e0d62883d58d8d4dc734286",
  "ajv/dist/compile/codegen/scope.js.map": "a5a146bfb90c9f6cb861d91503437e230f340c410a63400530e1bf493d84b0ec",
  "ajv/dist/compile/errors.d.ts": "cd44995ee13d5d23df17a10213fed7b483fabfd5ea08f267ab52c07ce0b6b4da",
  "ajv/dist/compile/errors.js": "53990f8f2cc05922bba410ae68231d3f869de4f8343277ede5b4834fa564c6c2",
  "ajv/dist/compile/errors.js.map": "5dfef5ea1d9707666aadcda54e93bff03e3a7f9730aec490ac31e5203eccd294",
  "ajv/dist/compile/index.d.ts": "62d26d8ba4fa15ab425c1b57a050ed76c5b0ecbffaa53f182110aa3a02405a07",
  "ajv/dist/compile/index.js": "05b34da22814f3787bfa3ac68dad59c9047f56e55a607e0a20719ebf5afe69ac",
  "ajv/dist/compile/index.js.map": "ad95a3a7cce920acd10b89d06581e3e2542bd0b6a4b44320b55bd18531efe99a",
  "ajv/dist/compile/jtd/parse.d.ts": "122c92735f34b67fac27fe091234cc879010acb26f67e130951a90feb68c0c49",
  "ajv/dist/compile/jtd/parse.js": "548b7e6ee5558360945f261e092cd328662868995877140ed2ae7ff981300b7f",
  "ajv/dist/compile/jtd/parse.js.map": "90e560b9f7e4b32959b514576dbb0d3a9dc3466e0ea65e0f3ac53e7bb34ab1c0",
  "ajv/dist/compile/jtd/serialize.d.ts": "173d6861b4b5265329e78219a2dc7e5b05a805337707f4de5ff4f7842a3ba0f9",
  "ajv/dist/compile/jtd/serialize.js": "1f8b1873fbd899240cd625144d3cd10630b3cf1b0c69c640566f6e25c80765c0",
  "ajv/dist/compile/jtd/serialize.js.map": "faaa5b0f5f27386d08abac9a54613bb4823fb5991b666715ab475ea85b391acd",
  "ajv/dist/compile/jtd/types.d.ts": "456178f9a8feccf812324213ac362aa49fd3e7df4369e409d398ff072629cfa5",
  "ajv/dist/compile/jtd/types.js": "e92a89e57c3b7d228be4e2e74c71ef3af52320bf061b411add9dccc34ddb0a78",
  "ajv/dist/compile/jtd/types.js.map": "b1c351a2a5810e00c4bbf3814fdc6b83fde3b016a79b8c5fc66cb32a0988abb5",
  "ajv/dist/compile/names.d.ts": "fd8346be5f0bb7a9ea588a343420bcd88b12da1bcd40c2d09c7a0d2990b51576",
  "ajv/dist/compile/names.js": "3cab37a2240b996b9bed92fe7a041d91689cfe3ad2e9ae4c0ab99e4146408493",
  "ajv/dist/compile/names.js.map": "2b28eacf577a5b5b2a6bade9e61097af1e84a4fb848fca153432e5c5a239e7d7",
  "ajv/dist/compile/ref_error.d.ts": "3d7f9eb12aface876f7b535cc89dcd416daf77f0b3573333f16ec0a70bcf902a",
  "ajv/dist/compile/ref_error.js": "81c98fdf34c3037c91bfcc02277ec32156c71e34048f36cfe4e084416e916cb7",
  "ajv/dist/compile/ref_error.js.map": "3101f665a6485ffee1c377d4cc015d9bb23af186ec941907afe03386406adc4b",
  "ajv/dist/compile/resolve.d.ts": "e0205f04611bea8b5b82168065b8ef1476a8e96236201494eb8c785331c43118",
  "ajv/dist/compile/resolve.js": "df75af0e0cf03fa1c6452e8dc61019f5aec645a8a5f6f494dc4e13cb5502d2d9",
  "ajv/dist/compile/resolve.js.map": "837e46750307e91c812466a0549472678800b29c1d3c9373f41fd795cb88c5ce",
  "ajv/dist/compile/rules.d.ts": "2973b1b7857ca144251375b97f98474e9847a890331e27132d5a8b3aea9350a8",
  "ajv/dist/compile/rules.js": "ec1d86500f497aa8e20f9f0c1695951159d9a909669d00a261ce1bb22b3cf0a9",
  "ajv/dist/compile/rules.js.map": "d5c077c6e1149c7e92fcaae92def87cd549f9407acbbcaf5a27dd5a76fab67c6",
  "ajv/dist/compile/util.d.ts": "0eb6152d37c84d6119295493dfcc20c331c6fda1304a513d159cdaa599dcb78b",
  "ajv/dist/compile/util.js": "fa911f5631f29d4d6420adfe086cb693b94b08de2719475c78c54bcb82f831a5",
  "ajv/dist/compile/util.js.map": "9deb815ce282c61c7e68adbd649aa7efe1e58f49e0b5c18d022d2f3b3717f442",
  "ajv/dist/compile/validate/applicability.d.ts": "b6f3050f59028cbed94bc895d15ac095d104c810a8201a01fac608c5780e7d1d",
  "ajv/dist/compile/validate/applicability.js": "50c5cba5894a7fb9874b3432355b46ec71b73c9368dafb1323ded8567cca8fc0",
  "ajv/dist/compile/validate/applicability.js.map": "399e5834d6364657feb5c799d87ca3141e8e653ef021b38489937319d7c4f2ad",
  "ajv/dist/compile/validate/boolSchema.d.ts": "7a69c4963a745bc7e9adfc025e0d02b1f0236d1f9e36636d4f8bd0d5210a19ac",
  "ajv/dist/compile/validate/boolSchema.js": "c08abdbdbd3d8b1dcc0552a20fbc7d837ed44f4ca6abb2e464985590ac94377f",
  "ajv/dist/compile/validate/boolSchema.js.map": "d2ba3c7b7cc92d4f4488e5dd785ded04ad4a42cdc69c68c45f929566edcf7ab9",
  "ajv/dist/compile/validate/dataType.d.ts": "7557d4d7f19f94341f4413575a3453ba7f6039c9591015bcf4282a8e75414043",
  "ajv/dist/compile/validate/dataType.js": "697bd7005361ec7066a23c18830a10b0ef28aec1a33138b4e3098bf78c4fae52",
  "ajv/dist/compile/validate/dataType.js.map": "5ddbd0361b1a521ba2e822ed40a7156d9d6211c68ef2c4677f6496c151ce9e08",
  "ajv/dist/compile/validate/defaults.d.ts": "0dfaa8ce667fa1388c2959200efab6337063a3e773930ae3e25dbd59d197018e",
  "ajv/dist/compile/validate/defaults.js": "05721971df94faa57b09c8cfd60c2eef81b6d14910a7dea5f539d693a029c428",
  "ajv/dist/compile/validate/defaults.js.map": "dd09145eaed811c656aeb2e9bf74d7aaafb4dc986a158cb20c017bdbde53d5b5",
  "ajv/dist/compile/validate/index.d.ts": "58ce1486f851942bd2d3056b399079bc9cb978ec933fe9833ea417e33eab676e",
  "ajv/dist/compile/validate/index.js": "cb2103e5f890e04592c10d24b45857dad91155bae9f9460138a2459bdaaea2cd",
  "ajv/dist/compile/validate/index.js.map": "fc7822f544bb4db6d457c858c53ba2e6be77a55d35a192e67011e1c8dd4d9c5c",
  "ajv/dist/compile/validate/keyword.d.ts": "ce0682a5e73f166fb6e80ad8a46a26af187b524f1f5f5fcc54e4c33c0b36b131",
  "ajv/dist/compile/validate/keyword.js": "ab8f070c75c25eee9be5c837f364748909b58f5db66149a2beccbd2f66afeb76",
  "ajv/dist/compile/validate/keyword.js.map": "3051e66f0a88cfb62ce8de46e2ca85780e2f0b64f62fc1fa091e77af47a51b4e",
  "ajv/dist/compile/validate/subschema.d.ts": "237df26f8c326ca00cd9d2deb40214a079749062156386b6d75bdcecc6988a6b",
  "ajv/dist/compile/validate/subschema.js": "ca783d6052af91e65ebb59a5b48b47fb459a2241d37ca6a042f767d4ce451bdc",
  "ajv/dist/compile/validate/subschema.js.map": "9a6beb742ae31a368004b444fb9ecaa49899eefe05e747e36c11b82e6a2c288a",
  "ajv/dist/core.d.ts": "4304f640f7cb4724ea82441accb7c7607fa7207541182470d625adda99b2900b",
  "ajv/dist/core.js": "51be29c7ed7288622f755c0f1bebd3da4a9907d77aa2c33b0f2a0a5b6b339603",
  "ajv/dist/core.js.map": "0357910e20ce75d511ca46f838803be796d605fcddecbc325131a82fcfc04472",
  "ajv/dist/jtd.d.ts": "88dfdb2a44912a28aea3ebb657dc7fcec6ba59f7233005e3405824995b713dac",
  "ajv/dist/jtd.js": "9554827c19abbb10694cafb71edd72a8303ea71e56b9eb7253200f5395610e44",
  "ajv/dist/jtd.js.map": "b8d25a9ac802a23e0e008abcbe4a9684a1bad31fd36b5e977e677527d6087f51",
  "ajv/dist/refs/data.json": "d24ab8a97c18b3f5afdde7d7024a0e0ac1df0614a16a41cb88f81379edcc2db3",
  "ajv/dist/refs/json-schema-2019-09/index.d.ts": "2a181e3ce12d234dc189bc5d8ec5a7977eeb3fdbbdd0551290d18da23a0afcec",
  "ajv/dist/refs/json-schema-2019-09/index.js": "ec400bdf35a0f290266811503cdbfffd7c18c4a690379988b8062c57b48f946d",
  "ajv/dist/refs/json-schema-2019-09/index.js.map": "3ba84273c35f49642ee68ddf2ea561e8ecbaf00329e323e210c8b6f6cc580e01",
  "ajv/dist/refs/json-schema-2019-09/meta/applicator.json": "9c356a52b0ad5da7d4c1b69f61dff5277c2af46221bc0b0521bbdbf3a12d3a2a",
  "ajv/dist/refs/json-schema-2019-09/meta/content.json": "cf4792ae93f4a4580ec9523640945f7756f75fd624935ebf15194b0ac3909267",
  "ajv/dist/refs/json-schema-2019-09/meta/core.json": "629c017994ffaa33f573a96cf01b9dac6cae80c7d5d17dad5e823a3afa18d5fe",
  "ajv/dist/refs/json-schema-2019-09/meta/format.json": "018ef7c81bcca9e40a4a02ed236e7cabb3a630f2b1ea01fbdeed2f882c15ddc8",
  "ajv/dist/refs/json-schema-2019-09/meta/meta-data.json": "e038593d36bf1855875a13b8812469d6a2d62ed309436b9c9a2fa5a4ba59085e",
  "ajv/dist/refs/json-schema-2019-09/meta/validation.json": "aaba7f2d6fcbdfa6ca97fdc3d3da1ae7d66ca3322b7e90cf5a98b067555d06e6",
  "ajv/dist/refs/json-schema-2019-09/schema.json": "264720afa0dd61919e21bbe9bc1312121b70e43019ac696240e069adc72cce15",
  "ajv/dist/refs/json-schema-2020-12/index.d.ts": "7d2eaeb15b579ef0682c2a88dcd2b4b13b653a31239fdc0096201024b1d9d87d",
  "ajv/dist/refs/json-schema-2020-12/index.js": "2e39089b0aaa14efa7901ecf5384622ec3d5897b206e1d589d2420f17b9fa6e1",
  "ajv/dist/refs/json-schema-2020-12/index.js.map": "79fed7d771c96ee134e413a39cac77f0e670228a684e1cbb58cfb0603a8f9877",
  "ajv/dist/refs/json-schema-2020-12/meta/applicator.json": "f1e465ff0c0cc86bee5c0cc4b51d2734c532e6ea12c75b60a2ac093a4577b2d4",
  "ajv/dist/refs/json-schema-2020-12/meta/content.json": "7ede86f2c48d646202bf1332aefaf46db268c943d59752727db7247dc2920516",
  "ajv/dist/refs/json-schema-2020-12/meta/core.json": "c3a5947992d4fe67c95cda7910911207376bbae41c0a124ec9e7e699172e7a49",
  "ajv/dist/refs/json-schema-2020-12/meta/format-annotation.json": "1e31131b1ed21f98c007f04deb501343b8c4dd77f1c5a8494a9c2085f68d769d",
  "ajv/dist/refs/json-schema-2020-12/meta/meta-data.json": "eb008c756b29bdaa237c1f06d32ea4a21f6ef22148b03c6372cea5e4c0782273",
  "ajv/dist/refs/json-schema-2020-12/meta/unevaluated.json": "8f7f75f4274745faa32e4abdba12de99f49b21df225f52f723b5c62043b0edca",
  "ajv/dist/refs/json-schema-2020-12/meta/validation.json": "3cae7069843679429e4ada7df261bb8961fa34cac15be89296026e69af312092",
  "ajv/dist/refs/json-schema-2020-12/schema.json": "5333c7df76bceee098e865881d0808238dea836126c6c60b49299ec85c6c7a56",
  "ajv/dist/refs/json-schema-draft-06.json": "a9b6a00af20105009f0924cd7c02d811bbf70c579a96f1552579c3457111f687",
  "ajv/dist/refs/json-schema-draft-07.json": "f7e8b13cad4fecff9771f3626fef33e20e59027b90938a28fd9d2f6c17cd0773",
  "ajv/dist/refs/json-schema-secure.json": "b7840b4f1526eee47ac19780906a436d0c39df2aa3d505388caf18864085a421",
  "ajv/dist/refs/jtd-schema.d.ts": "3a4c2bcb267c132400e8193819dd07eda7055e5a9c997ad62e1c38dd6fb2e922",
  "ajv/dist/refs/jtd-schema.js": "ed529445bf027885182bbed71e5458baecec2d356a788b636ed9f0c7cdaccd92",
  "ajv/dist/refs/jtd-schema.js.map": "732b58ce3fbd6aaac7a2423daa1f8dc134ff07a2336dbb2c5d13efd91a94a11b",
  "ajv/dist/runtime/equal.d.ts": "0beb32fbffe3dd6f079b3460c125d7577c49a525dd81b3bd771c94aa0081aecc",
  "ajv/dist/runtime/equal.js": "c94467da09ee94e5d194483a7ab821b9bb3bf1c04397270f2ab53dea9de59274",
  "ajv/dist/runtime/equal.js.map": "addc8498c8bf12ce8d2dc33c34805d0940eca3692c66105d99e270793c85fcae",
  "ajv/dist/runtime/parseJson.d.ts": "daaf1281de5547ccaa34f77fd4800c97bdf6f2533424bb9f5d82e11300d48e24",
  "ajv/dist/runtime/parseJson.js": "1bc006064c98afbbb4fc03bef49db7e85dd9493fb54a7dc647d4344ad043848e",
  "ajv/dist/runtime/parseJson.js.map": "cd9de6145208c3b595ccab1a800d1b492c89ddf41f8b682909e8c96d6d6b5bc7",
  "ajv/dist/runtime/quote.d.ts": "7821d3f015198f3c0b8e817b5038dce921c2330614743f69c8062fda6a96ca7f",
  "ajv/dist/runtime/quote.js": "1061132b1475fce15821d2b41c74b9ac710f278a33f5dae3385458715cc962b2",
  "ajv/dist/runtime/quote.js.map": "299ec640699b8c7601d58d6446fa0f3c639b307166971226950c845a819a7dc9",
  "ajv/dist/runtime/re2.d.ts": "ed8fd507cffed16f39d0ae3f2dd2ec46d9fd5e7b00d4e2579bb559243597c435",
  "ajv/dist/runtime/re2.js": "e1a6849652ae9a099c36c9aee9d2efc7412c8f83c4b285142413af99a7238361",
  "ajv/dist/runtime/re2.js.map": "891ce3a6e69c7c08f3e13ab0a950c2def22137c1bcd1f3dff54391f796e122cc",
  "ajv/dist/runtime/timestamp.d.ts": "a52bc6a407b585e49fe61fba28db84066c96961709a4095ff20ff1fe7430f678",
  "ajv/dist/runtime/timestamp.js": "05cd4fc283b82af25a2a71ee5e587640c1d42945c74cea790627135fff338bef",
  "ajv/dist/runtime/timestamp.js.map": "4e4eb1e7923ca19f3935fdfb76dfa7ee88d2914be490b1d702ffab13bfce07fe",
  "ajv/dist/runtime/ucs2length.d.ts": "2423ad491126a769f9973dc3687b86286c5ea2cd52d3a1dd25604fa03f1da2f4",
  "ajv/dist/runtime/ucs2length.js": "1df012dd3d23fced07255a7204798004509687cb1f431ae0ab976db436bbd890",
  "ajv/dist/runtime/ucs2length.js.map": "5ad0a6c09c26dd193c807813a9a22304d7c4534af6f13361032ecedaf58e8a7d",
  "ajv/dist/runtime/uri.d.ts": "d2dfc80c21db9f151f6ccd49e3b6dc50e23476e7e4f475a1e3497f86c464dd65",
  "ajv/dist/runtime/uri.js": "d1d61baf97ed87d7310df847a78ed73d19c8cc003207bf5aaec977500bdb1578",
  "ajv/dist/runtime/uri.js.map": "7751d10beb734802801b650c3e934553f2b26ba26bc68b20796734b7f9fd9955",
  "ajv/dist/runtime/validation_error.d.ts": "cde493e09daad4bb29922fe633f760be9f0e8e2f39cdca999cce3b8690b5e13a",
  "ajv/dist/runtime/validation_error.js": "11bf5b4affc8114e5e7cdf65b93006c2d997ab60ada1152c22e136f9b828b815",
  "ajv/dist/runtime/validation_error.js.map": "833d51e4ffee8e2e21c53b6aca02bdf70349233e8620b36d093bfb6b0157bff2",
  "ajv/dist/standalone/index.d.ts": "dd753d8a80fbc019d9001e148b14cdc21c8e503e7afe747632ba87878ab05487",
  "ajv/dist/standalone/index.js": "361d58a7523548bb1b9c782135fae27e76d93c8feaba8c4d613331dbcd3b888f",
  "ajv/dist/standalone/index.js.map": "a1afc5f1e9166c87da0c8e96b39560ba7c2df532adb495ad2b39c2ebfce68860",
  "ajv/dist/standalone/instance.d.ts": "974948bdf0935ed1da8ec1aa9d71bebe07bfa4b67e1532b841831d053cc9d86b",
  "ajv/dist/standalone/instance.js": "4e14aa01e0cb8288fbb75deeb2e738950b0560bd02e1ad8974f391af4c9fc6f3",
  "ajv/dist/standalone/instance.js.map": "7f59241ec6792fa719f3151610ef417552e986f45eb7c2f368a5c19a9b6261f7",
  "ajv/dist/types/index.d.ts": "9941cbf7ca695e95d588f5f1692ab040b078d44a95d231fa9a8f828186b7b77d",
  "ajv/dist/types/index.js": "fc9c6096246805c2075c83ab1b96082eda2fc98c240a2502caa82f1966096b71",
  "ajv/dist/types/index.js.map": "dc7dd6ae1631a9726121bba97c02b42640360d3667f8650f78242d078693c4e6",
  "ajv/dist/types/json-schema.d.ts": "feeb73d48cc41c6dd23d17473521b0af877751504c30c18dc84267c8eeea429a",
  "ajv/dist/types/json-schema.js": "2e30aa0c0789b5af8248b081ddc14b439b48937730eb1be0ab28de2ca2353b28",
  "ajv/dist/types/json-schema.js.map": "c33ce191e73eead1689338837205402bb586032b089eafc83210e4e1f1a5b221",
  "ajv/dist/types/jtd-schema.d.ts": "25f1159094dc0bf3a71313a74e0885426af21c5d6564a254004f2cadf9c5b052",
  "ajv/dist/types/jtd-schema.js": "6755d0ec5a09cc74205d46089f814c88c1ce4363e56a55486c12a0a86942bd8d",
  "ajv/dist/types/jtd-schema.js.map": "c2840f14191be8435778a2a64a8e0600500dde376910b05c52865e2deafb09c9",
  "ajv/dist/vocabularies/applicator/additionalItems.d.ts": "a3b2cc16f3ce2d882eca44e1066f57a24751545f2a5e4a153d4de31b4cac9bb5",
  "ajv/dist/vocabularies/applicator/additionalItems.js": "7beb0fbda5e349907067c8398bb8cc3260a6267b6e5dff9793a5ab2171934099",
  "ajv/dist/vocabularies/applicator/additionalItems.js.map": "f8d4898f0f5a507cf88a43dbcffb4ae82e7bb600d56602513085151032aac571",
  "ajv/dist/vocabularies/applicator/additionalProperties.d.ts": "1fce9ecb87a2d3898941c60df617e52e50fb0c03c9b7b2ba8381972448327285",
  "ajv/dist/vocabularies/applicator/additionalProperties.js": "e237cb180cd2e3f2e676feb714d7dcc6a42116640f9db2ad830cd20d9dfc540a",
  "ajv/dist/vocabularies/applicator/additionalProperties.js.map": "90cae7b84831914a0513d8db46fbe45e39cceba6c8ab3b39d853bd6439edc95a",
  "ajv/dist/vocabularies/applicator/allOf.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/applicator/allOf.js": "98f46a6434ebe5f851b406480e18b776dd7f1bcc275e28c16a13bfef3cc067c7",
  "ajv/dist/vocabularies/applicator/allOf.js.map": "bc57edbf872aa33f295435a714b3612f887c29abf411aa114d2b92a89461ee5b",
  "ajv/dist/vocabularies/applicator/anyOf.d.ts": "ac52b775a80badff5f4ac329c5725a26bd5aaadd57afa7ad9e98b4844767312a",
  "ajv/dist/vocabularies/applicator/anyOf.js": "8d7368d4aebad0514b713191b934993b4f0bf570e1bab93b07dc69712db2cec5",
  "ajv/dist/vocabularies/applicator/anyOf.js.map": "c05bb310be6b4e46482835cfe8978d34a8591a57722661d039f685d6e1ebd2d3",
  "ajv/dist/vocabularies/applicator/contains.d.ts": "8deb39d89095469957f73bd194d11f01d9894b8c1f1e27fbf3f6e8122576b336",
  "ajv/dist/vocabularies/applicator/contains.js": "56165dc93cd8b0b4611db50a97f1e7d7f9af6c5ffe95a7a5b054d6eeaa7f6a8c",
  "ajv/dist/vocabularies/applicator/contains.js.map": "b6136d502d30985c5f9367214191e1a15f7ffffa7e66d38b5d90ce97c5fb3069",
  "ajv/dist/vocabularies/applicator/dependencies.d.ts": "a38a9c41f433b608a0d37e645a31eecf7233ef3d3fffeb626988d3219f80e32f",
  "ajv/dist/vocabularies/applicator/dependencies.js": "c1a83bf484b6fde4d268935f079ddba5e74a2f589dfc6d15ca2e20ba4d06ee5b",
  "ajv/dist/vocabularies/applicator/dependencies.js.map": "58bd7453681e4e1f067f12ee46b0963fbb7b3dd91d5635146e892021541ea0af",
  "ajv/dist/vocabularies/applicator/dependentSchemas.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/applicator/dependentSchemas.js": "d17d23755b0cf8699c180dd98b8b7270b688d2e4fe5a4c4fcc53ffdcc18ee58e",
  "ajv/dist/vocabularies/applicator/dependentSchemas.js.map": "acf03cc2df2951050a845f391f71d74a82cf2448b628a791cfc37a1ef12cdc69",
  "ajv/dist/vocabularies/applicator/if.d.ts": "dd7109c49f416f218915921d44f0f28975df78e04e437c62e1e1eb3be5e18a35",
  "ajv/dist/vocabularies/applicator/if.js": "42374ee5dc681433579cc689b0c4ae5343f5bf78d4d6a561722b9277c5335ec4",
  "ajv/dist/vocabularies/applicator/if.js.map": "ecf2c80d9856d1678e643d6f4c77a36cd7bec448594ec6034fb72b558fce8939",
  "ajv/dist/vocabularies/applicator/index.d.ts": "eee181112e420b345fc78422a6cc32385ede3d27e2eaf8b8c4ad8b2c29e3e52e",
  "ajv/dist/vocabularies/applicator/index.js": "5a61978f6d81bbabfa8b9ccb71d7de816ed6dd1fd7de5c72657439a76c2a7cb3",
  "ajv/dist/vocabularies/applicator/index.js.map": "0b98845a246a8859fa44824daf69b40fe465f65075e2db2121aace15214dcf50",
  "ajv/dist/vocabularies/applicator/items.d.ts": "65f1d4dd1e542c949d9ef11825c9d568e16affad2d5c0cf5d39c386e3b09d791",
  "ajv/dist/vocabularies/applicator/items.js": "fa87f74adc3aac1f1b5e3e7dddf73294e6850e1dd49ed131fca4352e9645c54e",
  "ajv/dist/vocabularies/applicator/items.js.map": "a20b4a4a1802ca7708a0e8bcbb69b3b604522eeab131008bae7e8490b87c434f",
  "ajv/dist/vocabularies/applicator/items2020.d.ts": "ac2b3b377d3068bfb6e1cb8889c99098f2c875955e2325315991882a74d92cc8",
  "ajv/dist/vocabularies/applicator/items2020.js": "c449ef64aec16263c7935293ed450cfc2da3ba66f6df5f99c3198c05f169838f",
  "ajv/dist/vocabularies/applicator/items2020.js.map": "8f28ef13b54491f634fbd00c89b87dab96f0e490e0065d5aeac3853345e906dc",
  "ajv/dist/vocabularies/applicator/not.d.ts": "5ef0597b8238443908b2c4bf69149ed3894ac0ddd0515ac583d38c7595b151f1",
  "ajv/dist/vocabularies/applicator/not.js": "ab2f2758d4ea97ac8763fe5540dd0f4d877859676fe5d6c750a18deca387f718",
  "ajv/dist/vocabularies/applicator/not.js.map": "c5b821f2b5cee147a5dbc645470a3528d1e87f3f9faa9f5a41cd353a075d60db",
  "ajv/dist/vocabularies/applicator/oneOf.d.ts": "6ae5b4a63010c82bf2522b4ecfc29ffe6a8b0c5eea6b2b35120077e9ac54d7a1",
  "ajv/dist/vocabularies/applicator/oneOf.js": "e2aeb6c22d49fd5f348bedcf7f5c4d7b31f5a05dd7ff1a0c531374c6968792a2",
  "ajv/dist/vocabularies/applicator/oneOf.js.map": "ebab3ad34f13bc50265cb5ef9943beeef9f4e65c97a64533081da51d765dd526",
  "ajv/dist/vocabularies/applicator/patternProperties.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/applicator/patternProperties.js": "0d43da49a82452c439ba990de7372ad5cedb663717918a5f6dae07025abff655",
  "ajv/dist/vocabularies/applicator/patternProperties.js.map": "a8103db59a1c72cd5fea553943b386d21f5544f40202cb1b1af7ef465142c8d1",
  "ajv/dist/vocabularies/applicator/prefixItems.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/applicator/prefixItems.js": "16264f7b3233a6dcb98b48700643efbd3ebc4d11e27b3eacffc83ccb5f44fb23",
  "ajv/dist/vocabularies/applicator/prefixItems.js.map": "1f3562cac09a9442410a3b01bdf1930bf4cbb3fc4840704c6c6327be37aec33c",
  "ajv/dist/vocabularies/applicator/properties.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/applicator/properties.js": "c896873ae7251093a2c8880545b69b6e8cb55c44817a53ec830a49818d74104f",
  "ajv/dist/vocabularies/applicator/properties.js.map": "33599345842c02b84401f6abc5b8df58023ffa180c148430a0e62d8eb2198ba3",
  "ajv/dist/vocabularies/applicator/propertyNames.d.ts": "8e1428dcba6a984489863935049893631170a37f9584c0479f06e1a5b1f04332",
  "ajv/dist/vocabularies/applicator/propertyNames.js": "b3411cfeaff8efd5e6de12971bb5dc339e64b61fbe62d3b950794c077315c2e7",
  "ajv/dist/vocabularies/applicator/propertyNames.js.map": "a606f571bd198bcc4d9414887a57650669989bd0795181d07310e08a46aaec64",
  "ajv/dist/vocabularies/applicator/thenElse.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/applicator/thenElse.js": "9bc42eb8699d57188a7ec2a710d3f38052f92bd78c5d4d0442cf98cf2ebbe22d",
  "ajv/dist/vocabularies/applicator/thenElse.js.map": "474cff337e6d5c8ac35258cfc1b98d82367934b6d6a31bc261da7058e1008e4e",
  "ajv/dist/vocabularies/code.d.ts": "83ca5b45121b732612f3bfb090ed559fc701e69f385d48597f3ae7f54c535076",
  "ajv/dist/vocabularies/code.js": "9212ddf8bd0a4c3b1c4b44cdadd141183b2b36f561b91d13df53c83911e3bf63",
  "ajv/dist/vocabularies/code.js.map": "1db25a8b2b7a34ad9d348246d6f849f61d4e29538a16ad6498d77b1c3497d534",
  "ajv/dist/vocabularies/core/id.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/core/id.js": "49c8eff694ce4371450c1f9986e934fcbf4bd143311caef5332113f29175bc11",
  "ajv/dist/vocabularies/core/id.js.map": "fdeedb6446a7ddac6fc0dc0094bd70af32d00dc908ae2564f5519c45f6cd0897",
  "ajv/dist/vocabularies/core/index.d.ts": "817911706e04e79b7ac726cf166ee8d833db6e132693c6a88936713f89551010",
  "ajv/dist/vocabularies/core/index.js": "f420e1011b95e27b54c58323a7ed4ffbd0a88cdb4496f771bb6782c2aa22d23e",
  "ajv/dist/vocabularies/core/index.js.map": "47810777e556d4dfd64ed64eea5a9553e2c2ad632bac15944c8aafb75da4236d",
  "ajv/dist/vocabularies/core/ref.d.ts": "22caaec568a45c8d7abc8abdfbe2acbe23dfc8137c143e6c6348bfdc640decd4",
  "ajv/dist/vocabularies/core/ref.js": "1422c1454b3621d890066042048f37746fe1cf213088307099816199889bbfd1",
  "ajv/dist/vocabularies/core/ref.js.map": "102a133a0c29f09af757ac3715b3fe8d98b60d3651a8c288fc8aec35c51e4745",
  "ajv/dist/vocabularies/discriminator/index.d.ts": "423d2ccc38e369a7527988d682fafc40267bcd6688a7473e59c5eea20a29b64f",
  "ajv/dist/vocabularies/discriminator/index.js": "b58b58025d2dbe5a6967376faec9295b860a338664c47037e9a1035c1e8fb88e",
  "ajv/dist/vocabularies/discriminator/index.js.map": "5dd1b53a8e69c78a9e4eaf155e5e6f9e3856814a529632403d6deecda6efc1b2",
  "ajv/dist/vocabularies/discriminator/types.d.ts": "3be71f4ce8988a01e2f5368bdd58e1d60236baf511e4510ee9291c7b3729a27e",
  "ajv/dist/vocabularies/discriminator/types.js": "2365341d1f30dc72cece7703e908e47aacb8f904b9f66ec4019fe889ae1e57fa",
  "ajv/dist/vocabularies/discriminator/types.js.map": "4ab17ff95b7fec251f810c0d2c7bf2d9814b9ec733134195b91df6cf11821eaa",
  "ajv/dist/vocabularies/draft2020.d.ts": "3ea35fd2f7b15955306658465892b2ff6e4bebb342b1a55baa65cbb9d3e5d62a",
  "ajv/dist/vocabularies/draft2020.js": "2d0dc3a14abd48a45ad1407a97f23a0f943fa5244923037f86e95a7de04a7445",
  "ajv/dist/vocabularies/draft2020.js.map": "a45cb9b26d482a3a9018d4815ba277e409b83571c09c3a1065b9ba3390a7f891",
  "ajv/dist/vocabularies/draft7.d.ts": "9218319bc0e9c5e5bd7ebf676273928785813f41ec5501c59bdc2c36dfaba8b1",
  "ajv/dist/vocabularies/draft7.js": "8c62022c6c3aa302c3ea6f6709a697fc9eb6385d243fa7c2156dbe9f02228170",
  "ajv/dist/vocabularies/draft7.js.map": "e556fccd950796d8b708fe1fa2aa8bcdc37ef037be9e3234be5297085d90cb62",
  "ajv/dist/vocabularies/dynamic/dynamicAnchor.d.ts": "ac1d23564824d637da12dca9543b75a4f104407450469d004783d317c48cb293",
  "ajv/dist/vocabularies/dynamic/dynamicAnchor.js": "78222a5b42bab186253d880f9af4b012394ae5988bfab78e79f2510caed0ccf7",
  "ajv/dist/vocabularies/dynamic/dynamicAnchor.js.map": "a1a2f8ca7533601839749c902345c3001c95af3566eb30636eb6994d6bcfc0e7",
  "ajv/dist/vocabularies/dynamic/dynamicRef.d.ts": "3d51d2dc8af506a0345db97741b398cb386a0f8a3c3f3075a9a602158182a73f",
  "ajv/dist/vocabularies/dynamic/dynamicRef.js": "acc2913c91d11ff57150dde1751cdd5d9f486a0cb156037870ede203273af917",
  "ajv/dist/vocabularies/dynamic/dynamicRef.js.map": "4050eb882360e99c6a92d89a3c4f83e84f7f9df4d8e5c235ff9da9805d721a8f",
  "ajv/dist/vocabularies/dynamic/index.d.ts": "4bca8e262b63afb07fc894cc4139df757fbabe511c6e47b99b99e9f6c3331d14",
  "ajv/dist/vocabularies/dynamic/index.js": "8c05d09948653957427f351d9c6172965b932a5663f7dcb63014a491a533cc0b",
  "ajv/dist/vocabularies/dynamic/index.js.map": "cae8a099e83300e7e71269dcbd1918b399d9fe4e11d82ca1ddb59547ab962c14",
  "ajv/dist/vocabularies/dynamic/recursiveAnchor.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/dynamic/recursiveAnchor.js": "9f6cb7e509f9deada1b884010f08c52876f8eace32dcf0e7da28f6d0d91f3f76",
  "ajv/dist/vocabularies/dynamic/recursiveAnchor.js.map": "14cfed1db7bb14734fd2d0d9dd4be341f16ef368d7890a90424e6646c1d0115f",
  "ajv/dist/vocabularies/dynamic/recursiveRef.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/dynamic/recursiveRef.js": "7b0c651e2c5b5218639cd3ad7e5162f1e226fc9814107a85f4c3e47f5138670d",
  "ajv/dist/vocabularies/dynamic/recursiveRef.js.map": "aa22a9e7bdfce86b5eb802e6d806dc7d835d58a0dbc9165d72777206380ed7f6",
  "ajv/dist/vocabularies/errors.d.ts": "2f9fde0868ed030277c678b435f63fcf03d27c04301299580a4017963cc04ce6",
  "ajv/dist/vocabularies/errors.js": "7758b311e7cba27a8ff8b99a5fcd8db6804265cbc48d2867b72bfe56823d36bc",
  "ajv/dist/vocabularies/errors.js.map": "d551cb2d686656a44924038afa1c337933a1e5f953a8e5f09837dc3895332675",
  "ajv/dist/vocabularies/format/format.d.ts": "596e5b88b6ca8399076afcc22af6e6e0c4700c7cd1f420a78d637c3fb44a885e",
  "ajv/dist/vocabularies/format/format.js": "6fae0d5124fd821b1a9959492f7d6d7b528bee8830d49a7a4759fc9a9ab81d5f",
  "ajv/dist/vocabularies/format/format.js.map": "35575d56b5d5b5140b5575388d6e8ab5cdc097123eabe8c1e1e2f6d742fffcc5",
  "ajv/dist/vocabularies/format/index.d.ts": "f5144b57a017760ef277fe7cdeb1707af63498721918b80650824ab23b75d791",
  "ajv/dist/vocabularies/format/index.js": "d5dad5f95c9c5f48f8ca956cdbb927aafc7b56baabfca8c0b0403d92c5ebeb67",
  "ajv/dist/vocabularies/format/index.js.map": "ad27029bd96489edc361684b818651562c0ba5eb6a0484bc52bcbb178e16e68d",
  "ajv/dist/vocabularies/jtd/discriminator.d.ts": "b91034069e217212d8dda6c92669ee9f180b4c36273b5244c3be2c657f9286c7",
  "ajv/dist/vocabularies/jtd/discriminator.js": "14df845b5ef760d96a3c62db8d4446840e3d408a248d1b92ba6db2260fca4da2",
  "ajv/dist/vocabularies/jtd/discriminator.js.map": "c3b235680e571d21f99900ac5be4ce3457399b6881926dea7b1f36978e3ec848",
  "ajv/dist/vocabularies/jtd/elements.d.ts": "c9b5632d6665177030428d02603aeac3e920d31ec83ac500b55d44c7da74bd84",
  "ajv/dist/vocabularies/jtd/elements.js": "b2cad5c59d7c8ce936cea240d70beb41404c729901a60f32013c4facdcacfd5b",
  "ajv/dist/vocabularies/jtd/elements.js.map": "2cfe04080ae8f1ff3a86805676dd57cb6e55134325d473fa36f57837d72eca05",
  "ajv/dist/vocabularies/jtd/enum.d.ts": "ac3bcb82d7280fc313a967f311764258d18caf33db6d2b1a0243cde607ff01a0",
  "ajv/dist/vocabularies/jtd/enum.js": "4a8b7fa05f94b2e67275445c6e8437c337b92f709d243ed30a48ba6a08a9a154",
  "ajv/dist/vocabularies/jtd/enum.js.map": "87baba23c330e61539325d324acb2697c83a94e86e2902d2da3a08bc606230ff",
  "ajv/dist/vocabularies/jtd/error.d.ts": "a6613ee552418429af38391e37389036654a882c342a1b81f2711e8ddac597f2",
  "ajv/dist/vocabularies/jtd/error.js": "d6896337eedc9b71a742912f776580918cb4de58a90b434cd39f152896da16f9",
  "ajv/dist/vocabularies/jtd/error.js.map": "4737604dbfbcf18ad231ff4188391cf349fc0238baa89062956fc56fa1703a6f",
  "ajv/dist/vocabularies/jtd/index.d.ts": "b0d06dbb409369169143ede5df1fb58b2fca8d44588e199bd624b6f6d966bf08",
  "ajv/dist/vocabularies/jtd/index.js": "c57d340cd0709479d8ea9f102549a8fd2a47a2c1f2e6fe7f0e14067fe6385d7d",
  "ajv/dist/vocabularies/jtd/index.js.map": "31b17824ebfbdb2d2e7f5ae6835627153d57e8ebe801ba93988e4df2fea6f028",
  "ajv/dist/vocabularies/jtd/metadata.d.ts": "74dbbaddae5c3d5fdea9df3c53cb0b4ac8a18a2098370dee6393c152ff8b6025",
  "ajv/dist/vocabularies/jtd/metadata.js": "237a4bcc04f1a59628ba35aab9bd7c02fa19a007bf026f75c562c20c7a63ab68",
  "ajv/dist/vocabularies/jtd/metadata.js.map": "b4815c6a53d59294b48ae16adb6bfa3f36a1052b2a23b3763124a8b27747c538",
  "ajv/dist/vocabularies/jtd/nullable.d.ts": "06aeb5ecbfc278df2941e3226dedecb838e64e02a6fab7518531854543ecb543",
  "ajv/dist/vocabularies/jtd/nullable.js": "ba6494ac04fb1c2654951e8c8a57861e324fafa0f6c3bd2e1716bea8eb5c823a",
  "ajv/dist/vocabularies/jtd/nullable.js.map": "4d28df1f7dbde477e3501ab0d049b5643b5e7911d59603ebb24161ba8ef00f08",
  "ajv/dist/vocabularies/jtd/optionalProperties.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/jtd/optionalProperties.js": "82b67841649a948b069c8e0cfab712eb883579690065a05658b7df7e4eddcc62",
  "ajv/dist/vocabularies/jtd/optionalProperties.js.map": "58c1f7d7f168abe67793982f655adaef8b76937875373a26552c840c3812b898",
  "ajv/dist/vocabularies/jtd/properties.d.ts": "46456824df16d60f243a7e386562b27bac838aaba66050b9bc0f31e1ab34c1f2",
  "ajv/dist/vocabularies/jtd/properties.js": "4a392193b708f69c25511ed059e80a70ea084585731817ad8e459364f479eb35",
  "ajv/dist/vocabularies/jtd/properties.js.map": "7323488a259181201748b81e3c70628ef17842fdcc9ff917859240369d7f5380",
  "ajv/dist/vocabularies/jtd/ref.d.ts": "e875ca9fddf2b2ba80afe86316bc19b2982a6da3482b29a5cf7cfb35e3d07a2e",
  "ajv/dist/vocabularies/jtd/ref.js": "4736880c610f3664a8c714fdb5cf4e9db9fcda1721691dcacad2e9796e937460",
  "ajv/dist/vocabularies/jtd/ref.js.map": "1f76ab8797ae96dadfb9f03bb0c170d822417224ec2e395431cd0d0a51922001",
  "ajv/dist/vocabularies/jtd/type.d.ts": "da47cb979ae4a849f9b983f43ef34365b7050c4f5ae2ebf818195858774e1d67",
  "ajv/dist/vocabularies/jtd/type.js": "f97e19f2c3042938f433cfad0c4500b3342d869719550246bd4fced479db8e1c",
  "ajv/dist/vocabularies/jtd/type.js.map": "8956607890334c9fd8eb242e2ae900c64e0c7ccc6879ce5f283fedadaa5e1fc2",
  "ajv/dist/vocabularies/jtd/union.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/jtd/union.js": "f8404ab539ecfc5f6eb1bc489cc541aad6bf79cf58beecfcfe671226678c3280",
  "ajv/dist/vocabularies/jtd/union.js.map": "53c59966c45cc6fb1276f8f933ea2f9fa79be5a91c2595a79d940c147abf5519",
  "ajv/dist/vocabularies/jtd/values.d.ts": "0697277dd829ac2610d68fe1b457c9e758105bb52d40e149d9c15e5e2fe6dca4",
  "ajv/dist/vocabularies/jtd/values.js": "6b98eb1fbe2686a7f26fbf1e8860f61bdc81fe47117c4f5a79d5ca1fc92138f2",
  "ajv/dist/vocabularies/jtd/values.js.map": "0dc547866a1329dbe62fb89f961c74611069ad797639acce2def6a185e657c6a",
  "ajv/dist/vocabularies/metadata.d.ts": "a63efeef4b2f74a79a7729d6d362a98e3c647a7a439711f3a43372e16c6223aa",
  "ajv/dist/vocabularies/metadata.js": "45c178744a7ec57e20c85ceeaea8d9f36b5663636ab7e495ea2c3c1bf4a58609",
  "ajv/dist/vocabularies/metadata.js.map": "7d888e73dee29bee063f1e98884e6a40386f5ee653a8ed6208e43b973a3542cd",
  "ajv/dist/vocabularies/next.d.ts": "0aa6d6107f533bac5f47e8ef5d7fcc39503e0cd547e16b6348d063a24b30a137",
  "ajv/dist/vocabularies/next.js": "491c4d9738e50a6c22b3090cb1df49911b4bb7c3b7dcafc2f2dd4c074c4d82e7",
  "ajv/dist/vocabularies/next.js.map": "79890db3838840ab79e117248e523f9d3c97742b042b02382326fb2bf14f0918",
  "ajv/dist/vocabularies/unevaluated/index.d.ts": "87d4054133a5812f28e73373903c8ed8cc4929fd2ed0aa14695e7140e12d24ed",
  "ajv/dist/vocabularies/unevaluated/index.js": "4e7936d1a55051e70e2ebbbfc8de94fbe7f1e7b055252df5a984481ea7c156a4",
  "ajv/dist/vocabularies/unevaluated/index.js.map": "8a4aff71617048ad134ff9d6773270168595b0268c5330d8450b90e71496f8be",
  "ajv/dist/vocabularies/unevaluated/unevaluatedItems.d.ts": "d4cad9dc13e9c5348637170ddd5d95f7ed5fdfc856ddca40234fa55518bc99a6",
  "ajv/dist/vocabularies/unevaluated/unevaluatedItems.js": "4d7010c39f1b7af4a2fe1a62e5b65c8f763d4e58ac3d710099d367659f5e4fda",
  "ajv/dist/vocabularies/unevaluated/unevaluatedItems.js.map": "03ade2a02a69c0b0bad0dbe74d70964daab47a65f5d4796cdb927edd00c06ec8",
  "ajv/dist/vocabularies/unevaluated/unevaluatedProperties.d.ts": "adddf736e08132c7059ee572b128fdacb1c2650ace80d0f582e93d097ed4fbaf",
  "ajv/dist/vocabularies/unevaluated/unevaluatedProperties.js": "665029a99612ec32e9bef99c9c4b09a4dc0be6c71d7b920594d414d404806ebe",
  "ajv/dist/vocabularies/unevaluated/unevaluatedProperties.js.map": "7eea70788f708b843fa81cecb7c90aef4ae473b2cb5f5cf9f3229d1025fcffc0",
  "ajv/dist/vocabularies/validation/const.d.ts": "1cf0d15e6ab1ecabbf329b906ae8543e6b8955133b7f6655f04d433e3a0597ab",
  "ajv/dist/vocabularies/validation/const.js": "ace994e9ab97a70899a9484794794f4be5ee03bfb3cf32242d3f091d77f0329a",
  "ajv/dist/vocabularies/validation/const.js.map": "5f9e6e0702178bf1ce990751be7fb9369403af96e7f724bc361da8c27b16d8ea",
  "ajv/dist/vocabularies/validation/dependentRequired.d.ts": "d70675ba7ba7d02e52b7070a369957a70827e4b2bca2c1680c38a832e87b61fd",
  "ajv/dist/vocabularies/validation/dependentRequired.js": "cd69a90089328b24d2232c12edae57858c14f66aaa56923c12929eb3d673e8fa",
  "ajv/dist/vocabularies/validation/dependentRequired.js.map": "62fd57bce66b2b2cffa208b30e7dab00011936f05ae2a5b075c04461663e06a4",
  "ajv/dist/vocabularies/validation/enum.d.ts": "7c9f98fe812643141502b30fb2b5ec56d16aaf94f98580276ae37b7924dd44a4",
  "ajv/dist/vocabularies/validation/enum.js": "61062b318a40eb52fc5a8283e7f4781db98349841744961ef4fe04a4722ebf22",
  "ajv/dist/vocabularies/validation/enum.js.map": "3d74c4a70ce905cb4c07c75fededfb51d7124e683cf4ce394e89835fad8b1a2b",
  "ajv/dist/vocabularies/validation/index.d.ts": "b3547893f24f59d0a644c52f55901b15a3fa1a115bc5ea9a582911469b9348b7",
  "ajv/dist/vocabularies/validation/index.js": "4a1839832de5f10ff423c1c0c6cb232b5b6e1b34980a28862cf56b2763136de4",
  "ajv/dist/vocabularies/validation/index.js.map": "42fce077fc1751290cef9a3b2e48546262724d61f91d44751e6e4075ce159ed4",
  "ajv/dist/vocabularies/validation/limitContains.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/validation/limitContains.js": "0ea6f2e43359add298e1ed9306fe5020c62e086392f2915f10226b01394b200d",
  "ajv/dist/vocabularies/validation/limitContains.js.map": "56076461ebadbfbbd25cf53a8eaf5e61368f325443f6fe8e6ed9bea5d7b24445",
  "ajv/dist/vocabularies/validation/limitItems.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/validation/limitItems.js": "49f0427d29b38aef2fa8aead26e68bda12deb9a2da22f7a7804ba0fed44e1fec",
  "ajv/dist/vocabularies/validation/limitItems.js.map": "4d8e8e8f64bd85fab47be9c03276d23d52421b18cdabe2962c8cac38d5109459",
  "ajv/dist/vocabularies/validation/limitLength.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/validation/limitLength.js": "379c28317faaf7784680b6049c3562692d3df6d65cce33f48e6c6c723beeeec2",
  "ajv/dist/vocabularies/validation/limitLength.js.map": "bc33ca19aa1613710c361b334d5387a178441fb79f368898dcdce1d8075f54f5",
  "ajv/dist/vocabularies/validation/limitNumber.d.ts": "25fbe57c8ee3079e2201fe580578fab4f3a78881c98865b7c96233af00bf9624",
  "ajv/dist/vocabularies/validation/limitNumber.js": "3dd4bd41dbfc76c522078ff54b6479683485c4e97faa04cfcfaf2d8cb0fb8e65",
  "ajv/dist/vocabularies/validation/limitNumber.js.map": "8fb0880eb5eba874c7424e9b5f4c6f14a436330a471e0c791b39248e1abf2d9f",
  "ajv/dist/vocabularies/validation/limitProperties.d.ts": "e99ba2bf1ceb28ce6a3e60093bd8cb09e05eca71d0004254d3baf97c02152564",
  "ajv/dist/vocabularies/validation/limitProperties.js": "8523a3f7b36c34882ca32b0ec71a2157d7930907cb86b778a97c1514fa6258ac",
  "ajv/dist/vocabularies/validation/limitProperties.js.map": "0d819ad8104004b82be28bb3e86c96eefbff850e0fc1bd21bf43678a17a2ebfa",
  "ajv/dist/vocabularies/validation/multipleOf.d.ts": "62cc8477858487b4c4de7d7ae5e745a8ce0015c1592f398b63ee05d6e64ca295",
  "ajv/dist/vocabularies/validation/multipleOf.js": "df128c2a6ca74ae57c65fbfe3aea8a101447a3ae8c41fd53cfc5693fa23cc8bd",
  "ajv/dist/vocabularies/validation/multipleOf.js.map": "ff3ca557d3ed080cc3397829b9641b11764118afa8ce3c97ec2f6f47ae0c8c69",
  "ajv/dist/vocabularies/validation/pattern.d.ts": "cc2a9ec3cb10e4c0b8738b02c31798fad312d21ef20b6a2f5be1d077e9f5409d",
  "ajv/dist/vocabularies/validation/pattern.js": "86e84206bfc6a66ef18bf1fe43fbc56ebe7f7f4d57841197b6d044c529e0c195",
  "ajv/dist/vocabularies/validation/pattern.js.map": "87277c96cf32b25da6e01a4ef46f202f741872a43f360af2838d209e114f5d77",
  "ajv/dist/vocabularies/validation/required.d.ts": "4b4fadcda7d34034737598c07e2dca5d7e1e633cb3ba8dd4d2e6a7782b30b296",
  "ajv/dist/vocabularies/validation/required.js": "b953bc18d94274bd73374dd5b4282d7a21159cec8c0e7a357e1eaf3f326b9054",
  "ajv/dist/vocabularies/validation/required.js.map": "93e4965462fa0e78f52e96498550ce19eca50f70872ffae95baeb4b59e66b1bd",
  "ajv/dist/vocabularies/validation/uniqueItems.d.ts": "360fdc8829a51c5428636f1f83e7db36fef6c5a15ed4411b582d00a1c2bd6e97",
  "ajv/dist/vocabularies/validation/uniqueItems.js": "666d1a2aa25c0dfe3cf41312d0f9d40e9f99eb2c19be7469134ad89005aadd52",
  "ajv/dist/vocabularies/validation/uniqueItems.js.map": "ca96cb4269f0665b48201bbd3bf767583b2d337cc6bfd1f8e3135c54c09780b5",
  "ajv/lib/2019.ts": "d56766ac02c001a4f808c99281e466c4ed004118169e1d93b1b383dbe8ebfdbc",
  "ajv/lib/2020.ts": "0172fbdd0f09d7cec4243374ef3148da91ac504b436c1b058bbb482fdb1ad603",
  "ajv/lib/ajv.ts": "db86e7216e623df616513e1191e428b8d73c9f2cb1a36720fff0f12003d22a85",
  "ajv/lib/compile/codegen/code.ts": "3e088cc949e98ccef11611d64f11b3035182c257dd055587f3cc3081b59b8f85",
  "ajv/lib/compile/codegen/index.ts": "5d36911057430b7beedd1acf8026afb6529a09bf8b974c47d68d9a72be252ea6",
  "ajv/lib/compile/codegen/scope.ts": "a4cc6bc51633c0a67e09d61926a769a4d805f13931fd3541957a8e80d2b86a16",
  "ajv/lib/compile/errors.ts": "088cd10b6fb1e7ee6fde64d791f17d06f9b79cb126c35f98ae02cffafec44480",
  "ajv/lib/compile/index.ts": "fd39c4872a98fd27d899345d92da8b5e9c92a3b311a9f91e156080349f85c869",
  "ajv/lib/compile/jtd/parse.ts": "3f987db29f450b9463fc64a2d594325d21155d3e7934a143ab1a744ce0d7ecd6",
  "ajv/lib/compile/jtd/serialize.ts": "f523467687cad8197f51828d97dba711087fd7fb7447626a672823fcc227f6b7",
  "ajv/lib/compile/jtd/types.ts": "4f9a151d6cb7028d5eb483a2f0aab17a2f8a411b0af6b48108712cf6448b0822",
  "ajv/lib/compile/names.ts": "7e985cf51593c03cfac0317c9cceecddc70ab630673a3f5af739885255b2be64",
  "ajv/lib/compile/ref_error.ts": "1a3246eb3a9a09e185099600b550185a5fe84b22e27d854ddc7273d5e35315ac",
  "ajv/lib/compile/resolve.ts": "83fa181288f15f4be781fe8baa6735fcfee169efbf3f7710a86a50c6cac5acb5",
  "ajv/lib/compile/rules.ts": "d736019109db360c5bb5d5fb12132a0d518ff3c01238c93b8f317a2879cbdf85",
  "ajv/lib/compile/util.ts": "2f9441df72d2d7996f90403f5f31d6d156036a9e8e39a773a3e52812462dbcad",
  "ajv/lib/compile/validate/applicability.ts": "22a43ed9cc6d17524013990d049d96494db39c95f1122e103c01dfc87a820497",
  "ajv/lib/compile/validate/boolSchema.ts": "e5c41cd20170d246d1d40ac54bf7df4cbef084238d27f2a8d69faa2d597600cf",
  "ajv/lib/compile/validate/dataType.ts": "37adffaf46b9648699ea8b08a3caf6d5d031de027b955dd5f69ad2a72e7f03e3",
  "ajv/lib/compile/validate/defaults.ts": "8ae3dec515bbf81721af940ed1ca3ff1edbbb5e2c24187f441822c89e3925c27",
  "ajv/lib/compile/validate/index.ts": "841338dea0ff90d44bde71f0651879edad186fd50d7bb6d03243b0085e557c48",
  "ajv/lib/compile/validate/keyword.ts": "83e14ccb96fb8e24bb81af1c0d12a724472f713faf5ff2af2a8fd1be43da273f",
  "ajv/lib/compile/validate/subschema.ts": "79eb0fbb091074cdbc7149f3fe6bf0c174f76f53f82cf90f346285505eb4113e",
  "ajv/lib/core.ts": "c9a2785949f4ba6dbe26c536a95437f38cf688cf74301666c8a33a816ae5030d",
  "ajv/lib/jtd.ts": "e7157f96fc310c1488fdc78d12c6c33f3064d23859049e5d1fffa0a21d57f262",
  "ajv/lib/refs/data.json": "d24ab8a97c18b3f5afdde7d7024a0e0ac1df0614a16a41cb88f81379edcc2db3",
  "ajv/lib/refs/json-schema-2019-09/index.ts": "b0650c20759d7c19f624f1a7c8f3688eb7833a9ff964598dc0d4513e685d6b8d",
  "ajv/lib/refs/json-schema-2019-09/meta/applicator.json": "9c356a52b0ad5da7d4c1b69f61dff5277c2af46221bc0b0521bbdbf3a12d3a2a",
  "ajv/lib/refs/json-schema-2019-09/meta/content.json": "cf4792ae93f4a4580ec9523640945f7756f75fd624935ebf15194b0ac3909267",
  "ajv/lib/refs/json-schema-2019-09/meta/core.json": "629c017994ffaa33f573a96cf01b9dac6cae80c7d5d17dad5e823a3afa18d5fe",
  "ajv/lib/refs/json-schema-2019-09/meta/format.json": "018ef7c81bcca9e40a4a02ed236e7cabb3a630f2b1ea01fbdeed2f882c15ddc8",
  "ajv/lib/refs/json-schema-2019-09/meta/meta-data.json": "e038593d36bf1855875a13b8812469d6a2d62ed309436b9c9a2fa5a4ba59085e",
  "ajv/lib/refs/json-schema-2019-09/meta/validation.json": "aaba7f2d6fcbdfa6ca97fdc3d3da1ae7d66ca3322b7e90cf5a98b067555d06e6",
  "ajv/lib/refs/json-schema-2019-09/schema.json": "264720afa0dd61919e21bbe9bc1312121b70e43019ac696240e069adc72cce15",
  "ajv/lib/refs/json-schema-2020-12/index.ts": "9c4f608142c423538ffee89094935d3dede32664a1fc47c3cb4b248550946000",
  "ajv/lib/refs/json-schema-2020-12/meta/applicator.json": "f1e465ff0c0cc86bee5c0cc4b51d2734c532e6ea12c75b60a2ac093a4577b2d4",
  "ajv/lib/refs/json-schema-2020-12/meta/content.json": "7ede86f2c48d646202bf1332aefaf46db268c943d59752727db7247dc2920516",
  "ajv/lib/refs/json-schema-2020-12/meta/core.json": "c3a5947992d4fe67c95cda7910911207376bbae41c0a124ec9e7e699172e7a49",
  "ajv/lib/refs/json-schema-2020-12/meta/format-annotation.json": "1e31131b1ed21f98c007f04deb501343b8c4dd77f1c5a8494a9c2085f68d769d",
  "ajv/lib/refs/json-schema-2020-12/meta/meta-data.json": "eb008c756b29bdaa237c1f06d32ea4a21f6ef22148b03c6372cea5e4c0782273",
  "ajv/lib/refs/json-schema-2020-12/meta/unevaluated.json": "8f7f75f4274745faa32e4abdba12de99f49b21df225f52f723b5c62043b0edca",
  "ajv/lib/refs/json-schema-2020-12/meta/validation.json": "3cae7069843679429e4ada7df261bb8961fa34cac15be89296026e69af312092",
  "ajv/lib/refs/json-schema-2020-12/schema.json": "5333c7df76bceee098e865881d0808238dea836126c6c60b49299ec85c6c7a56",
  "ajv/lib/refs/json-schema-draft-06.json": "a9b6a00af20105009f0924cd7c02d811bbf70c579a96f1552579c3457111f687",
  "ajv/lib/refs/json-schema-draft-07.json": "f7e8b13cad4fecff9771f3626fef33e20e59027b90938a28fd9d2f6c17cd0773",
  "ajv/lib/refs/json-schema-secure.json": "b7840b4f1526eee47ac19780906a436d0c39df2aa3d505388caf18864085a421",
  "ajv/lib/refs/jtd-schema.ts": "76b788839e3f26ccbb073309b452595482714f2105295d009145d7b79e336003",
  "ajv/lib/runtime/equal.ts": "013de4ec7e4006015ef49ec787737636dc048a913aad0922295fc8b0eb15aa10",
  "ajv/lib/runtime/parseJson.ts": "79d1f9a5ae035324c73d85f146c00c19714f73a61d822470a12d28edd6be0fd5",
  "ajv/lib/runtime/quote.ts": "b87b625e0ca6a17d96c7af7999b7eaacc956c4265a49b54877d8fa9de295c1e3",
  "ajv/lib/runtime/re2.ts": "10841997f170df64628a12998362f97dec5052d06495a20ad72f725bd1bac2e7",
  "ajv/lib/runtime/timestamp.ts": "08509863a735667f2b8c5fb68d92f318947bd975cdf2a230ede606af96a8fbd4",
  "ajv/lib/runtime/ucs2length.ts": "a001c95dd2e835b9c61080254c117f02d425eb6760bd2c1d682ab63ed00d12f6",
  "ajv/lib/runtime/uri.ts": "4723aa43822e1cf2291029fe9038f317cca49ee685f59b2e48eb154f716a8edb",
  "ajv/lib/runtime/validation_error.ts": "abf8375d3a5d74512cc4d229e4839cf03b84d2e3904804401ca83cf7639e0a64",
  "ajv/lib/standalone/index.ts": "3509ccea2b4677c04074ccb9f6335ef63d36f183349d4c026dacc95928d096ed",
  "ajv/lib/standalone/instance.ts": "9fa1decae4056176ce7104da136af90419078307baafaeee947740e02eb4fc82",
  "ajv/lib/types/index.ts": "3cf1bd15564b691784b1bce4c6fa4223c0a3a8bde7b10d98270d7c66146aefa8",
  "ajv/lib/types/json-schema.ts": "4ccc0e648873df7580bb66a9d2e908604ddd96c69a88246dda60f5539e10bed8",
  "ajv/lib/types/jtd-schema.ts": "1c537a703005dbdf394539f58432861dae5135fddae6f54cebb28ae0f26f3d42",
  "ajv/lib/vocabularies/applicator/additionalItems.ts": "0593c60f31db5cea9022a353e56fd3066a8dac4e35607affb4e556d4d84c3f2a",
  "ajv/lib/vocabularies/applicator/additionalProperties.ts": "1ea5e25fd12131cae2278b7fc4fda354dad5a60d65234b67aaa09adf10268f55",
  "ajv/lib/vocabularies/applicator/allOf.ts": "cce43c2f5c51e2c1f40d9e773d052fc9e73beb775c5d6c0ae93e0bdb5a2a32fa",
  "ajv/lib/vocabularies/applicator/anyOf.ts": "2449024f686a1d8d51dc414849ae039465406adcf7ba04565d8ad2ba7448f594",
  "ajv/lib/vocabularies/applicator/contains.ts": "731c74710381d5484725d7e2bfa97e1f809a495ddae9bd0226a7c91578aeef05",
  "ajv/lib/vocabularies/applicator/dependencies.ts": "d2e648e8fe45621558c8f14ff5684954a91f6d800d1b2bf3d90f43941c84df65",
  "ajv/lib/vocabularies/applicator/dependentSchemas.ts": "ba8f82eb99b70d5e128c69719a15a703f3b5b95844923487fd8d12c5015200cc",
  "ajv/lib/vocabularies/applicator/if.ts": "676949dae0592465efcfdb3f15c8700fcc5e0b95bf0674c3b8723acbf2c3285f",
  "ajv/lib/vocabularies/applicator/index.ts": "85f01326e6589c9b0a8cc38939ac0520c5d213d55f6fefe2a9c23c7bdea680f6",
  "ajv/lib/vocabularies/applicator/items.ts": "9ccc7f93f03988881f366885fd3cc1a1490f36712b7932f3735f2f72136990e3",
  "ajv/lib/vocabularies/applicator/items2020.ts": "939a853b1f7b3a1ba3907453435dac558d11ba5c059ffc02c87107871ed2a668",
  "ajv/lib/vocabularies/applicator/not.ts": "a458fd0c8a2386906e5e55a2095c6176dc02dcfa19e13ec4ba775b51e2b56971",
  "ajv/lib/vocabularies/applicator/oneOf.ts": "ec3681fffbe66ae13befecacc4a400b3986b7819846b8e264320c189eff31ad0",
  "ajv/lib/vocabularies/applicator/patternProperties.ts": "80cb5e80c22228e2ce276b0703627f9057e40993b431a063a93abad5f92c3f75",
  "ajv/lib/vocabularies/applicator/prefixItems.ts": "ddddd4d635a17c56713d8938e78a7dc0c7688044ce1a5de033a6fd8e8ff96b0b",
  "ajv/lib/vocabularies/applicator/properties.ts": "76cd23a45c08a679f196d61e5b937e2a4361c92d9fc958a72d47ebc7efdba1f1",
  "ajv/lib/vocabularies/applicator/propertyNames.ts": "ab1b80a1a99dbf16578091b96b1347fda8f0177bfdee7ddbec161af54d01fa8f",
  "ajv/lib/vocabularies/applicator/thenElse.ts": "29a4fc78180fa88c422b01d2168c29087235238a2516d4c1800542503b5060e4",
  "ajv/lib/vocabularies/code.ts": "f4bf46f24e44512addfc8b34e8ef1cd6320025236839e176deb59ee8b20c7ee7",
  "ajv/lib/vocabularies/core/id.ts": "241606f9c18746cb35cb74c728c6d972bd6100edad70692bb27f841ac8b1b4b1",
  "ajv/lib/vocabularies/core/index.ts": "43e089e25baac37f7665f0451e51956ec154f60a058b83f86cc3e577ab800f62",
  "ajv/lib/vocabularies/core/ref.ts": "0d932d49ef57d32449923e5687e57715f4d08252f749d34d1d9410e8f88711f8",
  "ajv/lib/vocabularies/discriminator/index.ts": "9b89f8b9ab15e49b326bb3505424a1c0cd234397bf7db13a80e74e627fc381a3",
  "ajv/lib/vocabularies/discriminator/types.ts": "537bcd41ac270d1a43417d742a1f9f55b319e6f213323f6b00edfbe38e88e7da",
  "ajv/lib/vocabularies/draft2020.ts": "840c49657713cbbd6467274f270c77bf16a7ed8b3aedbee6bb5c587550282aea",
  "ajv/lib/vocabularies/draft7.ts": "9f8fd4fa8b2084b4cae951badc68de3a361e01eea06a158d530c4d55e92b5fb4",
  "ajv/lib/vocabularies/dynamic/dynamicAnchor.ts": "bc8bb7636e8fff1add5d8c36577978f357731c2877fd4d4c59b620d6a8af1d8f",
  "ajv/lib/vocabularies/dynamic/dynamicRef.ts": "92884e9923f4053155e5c1f13d5e176c17b47f0db65616bf031a4bb93faf969d",
  "ajv/lib/vocabularies/dynamic/index.ts": "c5188cd455c45b486350ed74bb08b6fb47db13bea6f218cce9d2cbf88044352b",
  "ajv/lib/vocabularies/dynamic/recursiveAnchor.ts": "7d9e31d581249212f5c831d30d5398c43b6d7ce4d3dcb735880524016b3e8d6a",
  "ajv/lib/vocabularies/dynamic/recursiveRef.ts": "6202321b7ce13fb3aec6d0180c3e78b6f91d768be57afef6b1693bd143577ee3",
  "ajv/lib/vocabularies/errors.ts": "ccf58af574cd4a8475346998967fa6229b163b6b52af2e9b0b30fa37338b8e2b",
  "ajv/lib/vocabularies/format/format.ts": "5cd796fed502ebe7f2c650b47daae97c28967dd17fa020df56ec861986d30148",
  "ajv/lib/vocabularies/format/index.ts": "804a833df34f93e7cd1a1809782f65c1ac89610ac736045308d27b659264a40a",
  "ajv/lib/vocabularies/jtd/discriminator.ts": "9dd6dd40e98239c10d6771c0a0d107e238c12af4b3c5932fe623de649588de1d",
  "ajv/lib/vocabularies/jtd/elements.ts": "54c00bc71c6bc0f5055c49fa0b6803db07832e5f77aadb1e55e5e045b3a4ad33",
  "ajv/lib/vocabularies/jtd/enum.ts": "a55ae1c6b7d9ac0e9053e71da407efe41b3156cc0db7091bcd20a9d8897844dd",
  "ajv/lib/vocabularies/jtd/error.ts": "e1bdb9dfada76ee42308e134f2e74027ea8398997961a3bae08cd10c792272c5",
  "ajv/lib/vocabularies/jtd/index.ts": "4ca3295374abddb3c03ada3fdc52b9b7cb175046769a3eef60605bef8a6ef85a",
  "ajv/lib/vocabularies/jtd/metadata.ts": "558fcb3d3b5e39a9a967326ea6a35160bd485755d587c5faafb644e25d0c0f01",
  "ajv/lib/vocabularies/jtd/nullable.ts": "75b370cb5ad4c36ff85a57fb9305a8018b5363666f0a5ac21c8de99d984b6bb8",
  "ajv/lib/vocabularies/jtd/optionalProperties.ts": "03fdaf041fd433857e78c3b867ad1e6c1f0a964c0292498981e238b40a2a4e77",
  "ajv/lib/vocabularies/jtd/properties.ts": "930071681288045214e10af6065f5d6c7f6ea599d07c607f345b609bac4bf8e5",
  "ajv/lib/vocabularies/jtd/ref.ts": "f7dc8a31ad5764cc0c44725713130d5b656ead77483429226507da4dfd24ad2d",
  "ajv/lib/vocabularies/jtd/type.ts": "0e6c6bb43fa81bff1cb4ba3f4d6d73379f3e013efaa01b790768fa0a5095cd45",
  "ajv/lib/vocabularies/jtd/union.ts": "1dd265ce69eebbd46cd395b0b9d98ca22d8e681d0ab787e6409cb126450c9536",
  "ajv/lib/vocabularies/jtd/values.ts": "86236891ca9a9f77f7df5d399be026406d0f375c0a5d8f6d0749859dea245cdd",
  "ajv/lib/vocabularies/metadata.ts": "a0b32538e6d2c93c7fd10aef9963d990d24d9579d2494350a23f3501300817d1",
  "ajv/lib/vocabularies/next.ts": "b953c63e395e4e0c95e048ae8778473a744e1d7a7b5fa8c57733c1bfbf7ce443",
  "ajv/lib/vocabularies/unevaluated/index.ts": "0d44afd298469f01304d72a5cf7da11303367fa506200c46785cee4bd3350f40",
  "ajv/lib/vocabularies/unevaluated/unevaluatedItems.ts": "c19c3d3e0b290171f674d3dbacc52d946f9e4325f2223355a055e741c5dbbbb2",
  "ajv/lib/vocabularies/unevaluated/unevaluatedProperties.ts": "7d725ffb348774d31cc697cc6b632a43431b3d2d92edb819fd7341902340c6de",
  "ajv/lib/vocabularies/validation/const.ts": "9dc3c40d6260158b2ee34dadadbc0e738cad939fc725cc1d2f5120bd43768ed5",
  "ajv/lib/vocabularies/validation/dependentRequired.ts": "082d569e899aca88dbe28bdf6a0c6c2efa120e107fe4d1244ecf3a0b17fef45b",
  "ajv/lib/vocabularies/validation/enum.ts": "f62f760dda52c2dbc053ef7b7012aa9db10d3af65e8b1dc5defcaf2ba9c25911",
  "ajv/lib/vocabularies/validation/index.ts": "72a7be83642b3da6317dc9661bfbc8a8f521773812ac6e5c58ddee1c4386a86c",
  "ajv/lib/vocabularies/validation/limitContains.ts": "3097c6f451ff7a527cbce136a08817114ee615f1b29221195cee45dfc89675e5",
  "ajv/lib/vocabularies/validation/limitItems.ts": "32098cc56bcd9ff44bfa83b1015a3bc2bb7d2f8f7eecb3113929df732faa8176",
  "ajv/lib/vocabularies/validation/limitLength.ts": "72afbaaa2718abe23156d8bb4af09fdc98a12054fe3c559b82e22718dbedb7de",
  "ajv/lib/vocabularies/validation/limitNumber.ts": "61bedba4a12924a84924b096f3b401356805cc24593f4b800bab4ad05be06298",
  "ajv/lib/vocabularies/validation/limitProperties.ts": "d55088c19cd829be5ff23dc7bb98dde9bb0bc9fb3baa2a4a141797044a668048",
  "ajv/lib/vocabularies/validation/multipleOf.ts": "5130cb4147d60dbec590b1e153f0f69b3c7ab552da9dd12eb2e1c22ca36daf7c",
  "ajv/lib/vocabularies/validation/pattern.ts": "7de916ef56aba5ef4d0b03e69b0e206224d1226728700afc7ccd76d216ff7829",
  "ajv/lib/vocabularies/validation/required.ts": "73f26a08d78ace7a164eca526843086bfbb986799d9a7ecc02fb67a87d2456aa",
  "ajv/lib/vocabularies/validation/uniqueItems.ts": "9d978fd6b3dc81c07c60f5067253490b54962571a4b510e18f4e257508809ee0",
  "ajv/node_modules/fast-uri/.gitattributes": "e173bffc6cde613d3e6d06e49f2b1d05385cb02aa68c4931656b5b051ab649dd",
  "ajv/node_modules/fast-uri/.github/dependabot.yml": "60ffc0c7159ff6af5e36ad3ecc56fe63782e4defaabafa94a13df7150d9a84c6",
  "ajv/node_modules/fast-uri/.github/workflows/ci.yml": "a5f799b1fd846548bd97adc494f1e0bc13919215b683235f5d3a30d2ad472736",
  "ajv/node_modules/fast-uri/.github/workflows/lock-threads.yml": "618dc46b9d589d991d97f4c9dd8b24c4f21edae32cdfd6c1ddc299dcab3d21d7",
  "ajv/node_modules/fast-uri/.github/workflows/package-manager-ci.yml": "7b086b40b64203092ce43638296c235ceba118d7b942fac7398ff476167876de",
  "ajv/node_modules/fast-uri/.github/workflows/release.yml": "4a5d4ec22a019815e0e9841f741ffacca7c13cbb98318f7c5398e6b3f35cfece",
  "ajv/node_modules/fast-uri/LICENSE": "b010b0dfdfdb23d7396e03b82cd4621fc9bb8f95d6b0aea70b9c24e12074c786",
  "ajv/node_modules/fast-uri/README.md": "a052a34b62b2de9e53052b1e8beac27de10826ea4098b533b6de5b744e61409d",
  "ajv/node_modules/fast-uri/benchmark/benchmark.mjs": "45ba9783c3258e448b05bd371161ef9fcbeed332ba1e9455ca9c98edb24e1f33",
  "ajv/node_modules/fast-uri/benchmark/equal.mjs": "36eb5b2acea9c4e969ab8fe028e88b781aa948e597368655a13528c3a93f1d39",
  "ajv/node_modules/fast-uri/benchmark/non-simple-domain.mjs": "303eb41faa6c2489b5086f3d2764bf6ecaf3b937b385647c6e8b14aaf2582524",
  "ajv/node_modules/fast-uri/benchmark/package.json": "463a034d344b042e495841b770ca69a812693087ee2053d7c18cc8497e020b58",
  "ajv/node_modules/fast-uri/benchmark/string-array-to-hex-stripped.mjs": "693d4a312b0e275e02ef5531d707ff7df6cddf14cd83bc09a79909ea2008bfd4",
  "ajv/node_modules/fast-uri/benchmark/ws-is-secure.mjs": "6f105dc633aadd4bd4b8362765f4a1d44fb31fe0c8754cb11d73f27ff7d6527b",
  "ajv/node_modules/fast-uri/eslint.config.js": "52e3a2601a98f23c954d664ab8de95fddb390789f8b067815e484b010d3da2d0",
  "ajv/node_modules/fast-uri/index.js": "528ad63bf9d97d888d716ea0c7fff01b5d7054980bb671f0353065b7a7e093f4",
  "ajv/node_modules/fast-uri/lib/schemes.js": "c2c61d3fd0bc63a587100928a399e75be8c420d210c439d75f7346da4aa4f3c3",
  "ajv/node_modules/fast-uri/lib/utils.js": "f97791a6c193027083b654d7428e0101aa2aaf5c2ab07a813cb8c1bf71d4ceb6",
  "ajv/node_modules/fast-uri/package.json": "06728ad83c4df979c6895d089452622441e34afe9b1c24584e2acac8d94a2876",
  "ajv/node_modules/fast-uri/test/ajv.test.js": "75892faa0e01df30856f2a87eb50dcd4a4aa9a3ec1c7aa4e290ff936b0789f72",
  "ajv/node_modules/fast-uri/test/component-safe-serialization.test.js": "354eb0c7c00d0a827d2351ccaeea702ac2c04f794fe6831ab7b8c15f7a7b15e4",
  "ajv/node_modules/fast-uri/test/equal.test.js": "9a2e83b204e7d9e14139dce7a13457a12b46f02189fb9138e1624bbd25d9b390",
  "ajv/node_modules/fast-uri/test/fixtures/uri-js-parse.json": "c954f79d2fa7f4d9779a6e7514cdf8df1eeb95d0097ea62cd3b785d20f2d0859",
  "ajv/node_modules/fast-uri/test/fixtures/uri-js-serialize.json": "c10203102fee328d6c8aedbd03319b8eeb364417c3b1137d714537fcd3102d69",
  "ajv/node_modules/fast-uri/test/host-delimiter-security.test.js": "3a3f18fef846fa6511a3a0d9b3f43012c79798f5981c3f9575661c78225af6a3",
  "ajv/node_modules/fast-uri/test/ipv6-canonical.test.js": "647cca74400388c5ea503c67433507a71fa371ba3377e5ddcec5204948b16968",
  "ajv/node_modules/fast-uri/test/ipv6-validation.test.js": "b34eae8daa2cd6717d6ff72098204692a393a0f4fbc6d47497557c42f28be79d",
  "ajv/node_modules/fast-uri/test/malformed-percent.test.js": "151bf26b0c6096adb923677c42ea33dfa2dabb999cd4dc07ce34f94aa8281fce",
  "ajv/node_modules/fast-uri/test/malformed-urn.test.js": "dfc01dbace807c71fab8e80acd154aeba25d1eca0aa2740681fa62d046bfe437",
  "ajv/node_modules/fast-uri/test/parse.test.js": "53d2c5bf0c198a834cb131dfd71795a30df6e49a28cedb1c62eec2d497192702",
  "ajv/node_modules/fast-uri/test/query-fragment-normalization.test.js": "18051e881d06450b5e33009e92c7582cc020b4dc39d636103370e0e8dd3ea0a6",
  "ajv/node_modules/fast-uri/test/relative-normalization-security.test.js": "3555771517284c6e7ee5bd8d3d72be4dd570544c699bb20125a684f507e4ad44",
  "ajv/node_modules/fast-uri/test/reserved-path-normalization.test.js": "a31767879b0d98cee31093457cd5373c84b1adae75d397931a45c8440fcc929e",
  "ajv/node_modules/fast-uri/test/resolve.test.js": "5f44df0de389cfb13848595184fd73a309ef7a702f55ebf5fc3cf0490ff7709c",
  "ajv/node_modules/fast-uri/test/rfc-3986.test.js": "b753dd115304e6cc567d2cb1169dd4d23641148274956fde0fabfdc612c65e27",
  "ajv/node_modules/fast-uri/test/scheme-validation.test.js": "fdf1a23b352f9e6cb7508af38065ac7654c0b406f9547d65dac6461d7d75e421",
  "ajv/node_modules/fast-uri/test/security-normalization.test.js": "a8a76693ee9035b8fa631a30269b4165a77f73f1174d376d4a596d25f6d03182",
  "ajv/node_modules/fast-uri/test/security.test.js": "ce2138c92e7c0f6cbad4cdc8e6d142b66ecf78af192b04771cd3b48c604dbb1d",
  "ajv/node_modules/fast-uri/test/serialize.test.js": "abb8f831a5ebcfe6d76d8d9abb2220bfe2d255892cab1f2b43d8ef3364f21ab4",
  "ajv/node_modules/fast-uri/test/uri-js-compatibility.test.js": "ca79aa1a3917c2bb237ab7e64235e4f1036a6ddacb66a5319845e8926cc89b28",
  "ajv/node_modules/fast-uri/test/uri-js.test.js": "dc3a3b9d0a532f6483bc2c11d13b865273afb7c74224e401ce6005a7fa0a834a",
  "ajv/node_modules/fast-uri/test/urn-full-input.test.js": "2f36727aafe2524ef08b8c5f1d124dea6971784ec9e96cffbf1986fba6c95718",
  "ajv/node_modules/fast-uri/test/util.test.js": "fa0595a97c1f948e641ea4696828a4d81c3389a986a45ac0a16feeffc73f8cad",
  "ajv/node_modules/fast-uri/test/websocket-query-preservation.test.js": "b3e7a45b622530f0c76910d7bdda2aa18b3b17a1d55b66e67dbb86d030fc0769",
  "ajv/node_modules/fast-uri/tsconfig.json": "6bbba68684f6d6f1613d9ae79de617c25d8d749f30942307faee46a6d2fd721f",
  "ajv/node_modules/fast-uri/types/index.d.ts": "84bcc7c6b06f4d643a55dc63b56be0c81d990f8d549b66ea615c553268774dc3",
  "ajv/node_modules/fast-uri/types/index.test-d.ts": "ad36147194c3ecfaecf55d75dd22f0b2c6b4ca476d6450cd307dceaf39012b46",
  "ajv/package.json": "1f9033ee5a6515e7d76938b7072941862d1ed228a6879cc7fe10cdeb75107989",
  "fast-deep-equal/LICENSE": "7bf9b2de73a6b356761c948d0e9eeb4be6c1270bd04c79cd489c1e400ffdfc1a",
  "fast-deep-equal/README.md": "ada32c1b53bd74640a22806e99b25c2b8ab2946eed338f325114be87bd5b9fce",
  "fast-deep-equal/es6/index.d.ts": "d979def17dea97ee491c975f3d3cb31957b7970a791c1d5a3854ea6cd4cce91e",
  "fast-deep-equal/es6/index.js": "d7f027497048c75e17268dbc66b670579d4f70f2dc0e019cdc9edf5078c247d6",
  "fast-deep-equal/es6/react.d.ts": "d979def17dea97ee491c975f3d3cb31957b7970a791c1d5a3854ea6cd4cce91e",
  "fast-deep-equal/es6/react.js": "366779cbb7821d26d18b9eaa12b6788cbb101cdbbabcae36f2919a5f48534ef0",
  "fast-deep-equal/index.d.ts": "37ffe3c12813b6a6d512f7c27b71f3388d03dafa10555ad5094cea393ed3d1f6",
  "fast-deep-equal/index.js": "eb469e206280321a3878f2335ec98aa2104a155079d8ed83a23029098dccd215",
  "fast-deep-equal/package.json": "a5c63940db0260739be9e2ac67f3aac268df4db5770420ee4e34e493152f97d2",
  "fast-deep-equal/react.d.ts": "d979def17dea97ee491c975f3d3cb31957b7970a791c1d5a3854ea6cd4cce91e",
  "fast-deep-equal/react.js": "37cbd168dbd42c73119ce7326556bddef40b3a5fbd2e215cf81a7c78fb73ff9a",
  "fast-uri/.gitattributes": "e173bffc6cde613d3e6d06e49f2b1d05385cb02aa68c4931656b5b051ab649dd",
  "fast-uri/.github/dependabot.yml": "fed0703d37709ec385b507e8e826709f94c3d72c8804487f918d16b862a265bb",
  "fast-uri/.github/workflows/ci.yml": "75cb9f8e4de167eca969255cd8591f065e32c1ce24915c3921bc1d4be92dd801",
  "fast-uri/.github/workflows/lock-threads.yml": "37dbbbadeff86c27af3c2357f3a098165064ddbe14dc4affa3eff614b772657e",
  "fast-uri/.github/workflows/ossf-scorecard.yml": "193af51e0e9c582029dc9e0019d1d1b642962f8305609601d73a5f3b5c7a3c0a",
  "fast-uri/.github/workflows/release.yml": "c72dde66d7f4eea32b3ec5356569eb4b654be3069e7bfbf38e302399de39bace",
  "fast-uri/LICENSE": "b010b0dfdfdb23d7396e03b82cd4621fc9bb8f95d6b0aea70b9c24e12074c786",
  "fast-uri/README.md": "56311b6c4c42ee41a01eba3bf161f766578af3a98925a3792bf724cf64ed28c1",
  "fast-uri/SECURITY.md": "2f169141c9855decbd76eb9a44e4946a19b248604829ae9286ed14556e4f26aa",
  "fast-uri/benchmark/benchmark.mjs": "94367909523f616ed8f090d5c3b55ceaff49a12b903f3ec829d9d534b464174e",
  "fast-uri/benchmark/encoder.mjs": "fd06c2dc44a23b417595ca0175e632b6814ea880077a67a26772ed302c19a6f7",
  "fast-uri/benchmark/equal.mjs": "36eb5b2acea9c4e969ab8fe028e88b781aa948e597368655a13528c3a93f1d39",
  "fast-uri/benchmark/non-simple-domain.mjs": "303eb41faa6c2489b5086f3d2764bf6ecaf3b937b385647c6e8b14aaf2582524",
  "fast-uri/benchmark/package.json": "463a034d344b042e495841b770ca69a812693087ee2053d7c18cc8497e020b58",
  "fast-uri/benchmark/string-array-to-hex-stripped.mjs": "693d4a312b0e275e02ef5531d707ff7df6cddf14cd83bc09a79909ea2008bfd4",
  "fast-uri/benchmark/ws-is-secure.mjs": "6f105dc633aadd4bd4b8362765f4a1d44fb31fe0c8754cb11d73f27ff7d6527b",
  "fast-uri/eslint.config.js": "52e3a2601a98f23c954d664ab8de95fddb390789f8b067815e484b010d3da2d0",
  "fast-uri/index.js": "2e42a1862516bcc1a85f65acf370fd33da762411fac324d5796d7a4a90fd7ebd",
  "fast-uri/lib/schemes.js": "f7524e001d061e9f164f57df552c19e5a8e51ea53735f7ae9e0a8342373ea728",
  "fast-uri/lib/utils.js": "e6a79da9c40ceccf367b9b7c484c17bc3a97e737e72c4e23e485ec05a6281169",
  "fast-uri/package.json": "c181566b934b386b614dcd5d7aeb438ebd6bfaa6b3f54f187eccccb3983cfb48",
  "fast-uri/test/ajv.test.js": "75892faa0e01df30856f2a87eb50dcd4a4aa9a3ec1c7aa4e290ff936b0789f72",
  "fast-uri/test/c0-reference-security.test.js": "17bedc82b08852220f24c2119aba35c391c44ad8981c4f0fcdf652fecce9201b",
  "fast-uri/test/component-safe-serialization.test.js": "354eb0c7c00d0a827d2351ccaeea702ac2c04f794fe6831ab7b8c15f7a7b15e4",
  "fast-uri/test/equal.test.js": "5a29d94b18d837cdfb54947115a4780668b14cd88030243f55fb090d4a2c9e3c",
  "fast-uri/test/fixtures/uri-js-parse.json": "bc79392f033f75a491f4360f8cd50610375d9945f257b5d1a40f872f17e059c9",
  "fast-uri/test/fixtures/uri-js-serialize.json": "b00ff2ebe5274ed5e21106af5d2a93159294b74f1eaf55cccd9863915f25ee21",
  "fast-uri/test/host-encoding.test.js": "101790dc9e3a4389f1c3c146b3f3edc6f2473cca86db813d073f7ee11c0835dd",
  "fast-uri/test/ipv6-canonical.test.js": "647cca74400388c5ea503c67433507a71fa371ba3377e5ddcec5204948b16968",
  "fast-uri/test/ipv6-validation.test.js": "33cf34f31cb4c05a40e7cfdd492f40bf3c1cffe0549cb474e42822bac0c4fbdf",
  "fast-uri/test/mailto-authority-security.test.js": "b5c7ee0e9908fdf518e0a441edb7f4365d83fd28e47675ae804899909cac142a",
  "fast-uri/test/mailto-field-name-security.test.js": "ccefefd44d4192ab2bbfa1178aeea162c827509cd2fcda0b4c699c8e706171e7",
  "fast-uri/test/malformed-percent.test.js": "151bf26b0c6096adb923677c42ea33dfa2dabb999cd4dc07ce34f94aa8281fce",
  "fast-uri/test/malformed-urn.test.js": "dfc01dbace807c71fab8e80acd154aeba25d1eca0aa2740681fa62d046bfe437",
  "fast-uri/test/parse.test.js": "0946c313fae627734a4ca05944f3615cd0a18cdc966bfa8e1f8f969be1075a6b",
  "fast-uri/test/query-fragment-normalization.test.js": "18051e881d06450b5e33009e92c7582cc020b4dc39d636103370e0e8dd3ea0a6",
  "fast-uri/test/reserved-path-normalization.test.js": "984c6d447e4e0474b8b11c75cf2a5f54ffd855206dc588c8d5c47fd819fe7212",
  "fast-uri/test/resolve.test.js": "5f44df0de389cfb13848595184fd73a309ef7a702f55ebf5fc3cf0490ff7709c",
  "fast-uri/test/rfc-3986.test.js": "b753dd115304e6cc567d2cb1169dd4d23641148274956fde0fabfdc612c65e27",
  "fast-uri/test/scheme-normalization.test.js": "5d7a26e50b2a314b13f062e84f3a36449ee1e5db3bdceec8c9ffd0784e1f8093",
  "fast-uri/test/scheme-validation.test.js": "40b1b535d6358acbc79d1c7db357241b85bf7dbb8168232af8c2bf3bafaaa889",
  "fast-uri/test/security-normalization.test.js": "a8a76693ee9035b8fa631a30269b4165a77f73f1174d376d4a596d25f6d03182",
  "fast-uri/test/security-utf8-encoding.test.js": "b1bbb110e75953b1aa0211978a1ac11af2dbe068898da153cdf065f1ea48c954",
  "fast-uri/test/security.test.js": "43d2018b33bba3e2f2ba90eea2480f3eebb6ed5013b6463ad9168a3d48d57455",
  "fast-uri/test/serialize.test.js": "a0b12436f99595fb09b18695a79c394a738bedcd36546b7002a1b91c306b9a6c",
  "fast-uri/test/uri-js-compatibility.test.js": "7464559828ce69bf797b3908a6507b4377722f0cbd143b5e87d44bd85d637ef2",
  "fast-uri/test/uri-js.test.js": "f61d7288c0de69071dff40f8a66d4628f51ad16130e20e3a4e51f359082c1e8d",
  "fast-uri/test/urn-full-input.test.js": "dbc0f83921364a51c4f572f0d7a8cd758de6610837ea06bc49a7cbde8db867d7",
  "fast-uri/test/util.test.js": "efc8f431301ac46e00127ab28ae62bc52dc61da8b5f457b9573e66667644a063",
  "fast-uri/test/websocket-query-preservation.test.js": "b3e7a45b622530f0c76910d7bdda2aa18b3b17a1d55b66e67dbb86d030fc0769",
  "fast-uri/tsconfig.json": "652102759c2ba051297a981538a83cbb0a34ba989d1ad0d75a56a72659cc2be4",
  "fast-uri/types/index.d.ts": "21d7c72eeb9af9c887287011853c35ccb3edc4b8aa98d8610dc15273f3882a82",
  "fast-uri/types/index.tst.ts": "f58b233dc32b6b513fd3662e3c51a8576c280ccca1fbec6830eed902ae78b94b",
  "json-schema-traverse/.eslintrc.yml": "b1ea981e2461f053646b08a616efcaba0d3b278b223957e9eb931bcbc3971ccc",
  "json-schema-traverse/.github/FUNDING.yml": "83e77adf3dbe6261917b160553f75cbb96de8e99c3259f4f1de85e1c6e4bd156",
  "json-schema-traverse/.github/workflows/build.yml": "f0f23bb3b380800e214b19abfd69c1b093131bb030c056fabdd9cddec7e785c5",
  "json-schema-traverse/.github/workflows/publish.yml": "56cbec53748d486f04b5c37bec8ea5e5588e02fb2882db8ce36c6e9689bfd2fc",
  "json-schema-traverse/LICENSE": "7bf9b2de73a6b356761c948d0e9eeb4be6c1270bd04c79cd489c1e400ffdfc1a",
  "json-schema-traverse/README.md": "e6137660d373bc510f4d41789d7fea74e0ed9f94c99d4892dee22292ac2a39a7",
  "json-schema-traverse/index.d.ts": "a76003875cf31f09428a535df140f122f580b5bf811f996273d5aa2733feeadd",
  "json-schema-traverse/index.js": "024191b747afac01b28ff11d744e9f82720bbad5f716163ba5c962eb62aa2350",
  "json-schema-traverse/package.json": "156fb24af02845c190701360d06dfda35ef04282e34a734289ea9535ad9819ae",
  "json-schema-traverse/spec/.eslintrc.yml": "8df0cb64273b71c11db4f99be49c92e6f80f10a13de4599743e4372c8a0be82c",
  "json-schema-traverse/spec/fixtures/schema.js": "0262591e321bc88b22dc33ec78bcded5ab664e2fce2c10b9e0c35d3eb6030d27",
  "json-schema-traverse/spec/index.spec.js": "40e6986bda700387e2d397971087a3977d6801bf954591505229691a267c5f69",
  "require-from-string/index.js": "cb059342a762b955997bf780f3693add176922727f2fa9f11fcaf1b3fc323239",
  "require-from-string/license": "6ee0feb1f6ef996ff5a68600f8cf98909cf412d39ef3cdceaefd87d636fa1b7f",
  "require-from-string/package.json": "c0002f7d4c7d7e2a885cf0f97226344902417c3a0980f2beca41962d2bc1f6d8",
  "require-from-string/readme.md": "969286b710026d911ed5e09e5bdca2dbf1c921662defa2ad3a1b3760a0bdb213"
};
const checkpointWorker = String.raw`// Ordinary successful fresh-process execution of whole original modules.
// This is a fixture driver, not a replacement command, store, lock, or resume function.
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { runPipeline } from './upstream/package/dist/src/runtime.js';
import { stateGetCommand, stateSetCommand } from './upstream/package/dist/src/commands/stdlib/state.js';
import { diffLastCommand } from './upstream/package/dist/src/commands/stdlib/diff_last.js';
import { askCommand } from './upstream/package/dist/src/commands/stdlib/ask.js';
import { finalizePipelineToolRun, loadPipelineResumeState, validatePipelineInputResponse } from './upstream/package/dist/src/pipeline_resume_state.js';
import { consumeResumeState } from './upstream/package/dist/src/state/store.js';
import { decodeToken } from './upstream/package/dist/src/token.js';
import { llmProvenanceOf } from './upstream/package/dist/src/core/llm_accounting.js';

const [action, directory, payload] = process.argv.slice(2);
const fixtureRoot = fileURLToPath(new URL('./fixtures/', import.meta.url));
assert.ok(directory.startsWith(fixtureRoot), 'all state stays inside task fixtures');
const env = { LOBSTER_STATE_DIR: directory };
const registry = new Map([stateGetCommand, stateSetCommand, diffLastCommand, askCommand].map(command => [command.name, command]));
const stdout = { write() { return true; } };
const options = { registry, stdin: { isTTY: false }, stdout, stderr: stdout, env, mode: 'tool', renderOutput: false };
if (action === 'read') {
  const result = await runPipeline({ ...options, pipeline: [{ name: 'state.get', args: { _: [payload] }, raw: 'state.get' }] });
  process.stdout.write(JSON.stringify({ items: result.items, provenance: llmProvenanceOf(result.items[0]), usageProvenance: llmProvenanceOf(result.items[0]?.usage) }) + '\n');
} else if (action === 'start') {
  const same = payload === 'same_stage';
  const pipeline = [
    { name: 'state.get', args: { _: ['initial'] }, raw: 'state.get initial' },
    { name: 'state.set', args: { _: ['before_checkpoint'] }, raw: 'state.set before_checkpoint' },
    { name: 'ask', args: { _: [], prompt: 'Continue?', schema: '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"]}', emit: !same }, raw: 'ask' },
    { name: 'state.set', args: { _: ['reply'] }, raw: 'state.set reply' },
    { name: 'diff.last', args: { _: [], key: 'baseline_diff' }, raw: 'diff.last --key baseline_diff' },
  ];
  const output = await runPipeline({ ...options, pipeline });
  const finalized = await finalizePipelineToolRun({ env, pipeline, output });
  assert.equal(finalized.status, 'needs_input');
  const { stateKey } = decodeToken(finalized.requiresInput.resumeToken);
  const snapshot = await loadPipelineResumeState(env, stateKey);
  process.stdout.write(JSON.stringify({ status: finalized.status, request: { prompt: finalized.requiresInput.prompt, responseSchema: finalized.requiresInput.responseSchema }, stateKey, snapshot }) + '\n');
} else if (action === 'resume') {
  const previousState = await loadPipelineResumeState(env, payload);
  const response = { decision: 'approve' };
  validatePipelineInputResponse(previousState.inputSchema, response);
  const same = previousState.resumeMode === 'same_stage';
  const remaining = previousState.pipeline.slice(previousState.resumeAtIndex);
  let consumed = false;
  const output = await runPipeline({
    ...options, pipeline: remaining,
    input: same ? previousState.items : [response],
    requestInputResume: same ? { state: previousState.commandInput, response } : undefined,
    onExecutionStart: async () => {
      const result = await consumeResumeState({ env, key: payload, expectedState: previousState });
      assert.equal(result.consumed, true);
      consumed = true;
    },
  });
  const finalized = await finalizePipelineToolRun({ env, pipeline: remaining, output, previousStateKey: payload, previousState, previousStateConsumed: consumed });
  process.stdout.write(JSON.stringify({ finalized, consumed, files: (await fs.readdir(directory)).sort(), replyBytes: await fs.readFile(join(directory, 'reply.json'), 'utf8'), diffBytes: await fs.readFile(join(directory, 'baseline_diff.json'), 'utf8') }) + '\n');
} else {
  throw new Error('Unknown fixture action');
}
`;
await fs.writeFile(join(root, 'checkpoint-worker.mjs'), checkpointWorker);
const exec = promisify(execFile);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const collect = async output => { const values = []; for await (const value of output) values.push(value); return values; };
const ctx = directory => ({ env: { LOBSTER_STATE_DIR: directory } });
const set = (directory, key, input) => stateSetCommand.run({ input, args: { _: [key] }, ctx: ctx(directory) });
const get = (directory, key, input = []) => stateGetCommand.run({ input, args: { _: [key] }, ctx: ctx(directory) });
const diff = (directory, args, input) => diffLastCommand.run({ input, args, ctx: ctx(directory) });
async function fixture(fn) {
  await fs.mkdir(fixtureRoot, { recursive: true });
  const directory = await fs.mkdtemp(join(fixtureRoot, 'success-'));
  try { await fn(directory); }
  finally { await fs.rm(directory, { recursive: true, force: true }); }
}
async function fresh(action, directory, payload) {
  const { stdout, stderr } = await exec(process.execPath, [join(root, 'checkpoint-worker.mjs'), action, directory, payload], { timeout: 15000, maxBuffer: 1024 * 1024 });
  assert.equal(stderr, '');
  return JSON.parse(stdout);
}
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
const mark = (key, value) => markLlmItem(value, { cacheKey: key, replayed: false });

// Expectations below are independent literals, not generated with source or product serializers.
test('archive and all original package/dependency file bytes retain frozen SHA evidence', async () => {
  assert.equal(hash(readFileSync(archive)), 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1');
  const manifest = sourcePins;
  for (const [file, expected] of Object.entries(manifest)) assert.equal(hash(await fs.readFile(join(root, 'upstream', file))), expected, file);
  const dependencies = dependencyPins;
  for (const [file, expected] of Object.entries(dependencies)) assert.equal(hash(await fs.readFile(join(root, 'upstream/package/node_modules', file))), expected, file);
  assert.equal(JSON.parse(await fs.readFile(join(root, 'upstream/package/node_modules/ajv/package.json'), 'utf8')).version, '8.20.0');
});

test('pure key mapping and default directory resolution never write the home directory', () => {
  assert.equal(defaultStateDir({ LOBSTER_STATE_DIR: ' \t/tmp/fixture-state \n' }), '/tmp/fixture-state');
  assert.equal(defaultStateDir({}), join(homedir(), '.lobster', 'state'));
  assert.equal(defaultStateDir({ LOBSTER_STATE_DIR: ' \t ' }), join(homedir(), '.lobster', 'state'));
  assert.equal(defaultStateDir(undefined), join(homedir(), '.lobster', 'state'));
  for (const [key, filename] of [
    ['MIXED.Name-7', 'mixed.name-7.json'],
    ['___Alpha / Beta___', 'alpha_beta.json'],
    ['A雪😀B', 'a_b.json'],
    ['A\ud800B', 'a_b.json'],
    ['ÄA', 'a.json'],
    [42, '42.json'],
  ]) assert.equal(keyToPath('/fixture/state', key), '/fixture/state/' + filename);
});

test('state.set drains before publication and returns original references before lazy output consumption', async () => fixture(async directory => {
  await fs.writeFile(join(directory, 'timing.json'), '{"old":true}\n');
  const entered = deferred(), release = deferred();
  const first = { name: 'first' }, second = { name: 'second' };
  async function* input() { yield first; entered.resolve(); await release.promise; yield second; }
  const pending = set(directory, 'timing', input());
  try {
    await entered.promise;
    assert.equal(await fs.readFile(join(directory, 'timing.json'), 'utf8'), '{"old":true}\n');
  } finally { release.resolve(); }
  const result = await pending;
  assert.equal(await fs.readFile(join(directory, 'timing.json'), 'utf8'), '[\n  {\n    "name": "first"\n  },\n  {\n    "name": "second"\n  }\n]\n');
  first.name = 'mutated after publication';
  const [returned] = await collect(result.output);
  assert.equal(returned[0], first);
  assert.equal(returned[1], second);
  assert.equal(returned[0].name, 'mutated after publication');
  assert.deepEqual(await fs.readdir(directory), ['timing.json']);
}));

test('state.set zero, one, multiple, null, signed zero, and normal numeric serialization', async () => fixture(async directory => {
  const [zero] = await collect((await set(directory, 'empty', [])).output);
  assert.deepEqual(zero, []);
  assert.equal(await fs.readFile(join(directory, 'empty.json'), 'utf8'), '[]\n');
  const object = { b: 2, a: { x: 1 } };
  assert.equal((await collect((await set(directory, 'one', [object])).output))[0], object);
  assert.equal(await fs.readFile(join(directory, 'one.json'), 'utf8'), '{\n  "b": 2,\n  "a": {\n    "x": 1\n  }\n}\n');
  assert.deepEqual(await collect((await set(directory, 'null', [null])).output), [null]);
  assert.equal(await fs.readFile(join(directory, 'null.json'), 'utf8'), 'null\n');
  assert.ok(Object.is((await collect((await set(directory, 'signed', [-0])).output))[0], -0));
  assert.equal(await fs.readFile(join(directory, 'signed.json'), 'utf8'), '0\n');
  const [readZero] = await collect((await get(directory, 'signed')).output);
  assert.ok(Object.is(readZero, 0));
  const numbers = [-0, 1e21, 1e-7, 1e-6, 9007199254740991, 1.25];
  const [many] = await collect((await set(directory, 'many', numbers)).output);
  assert.deepEqual(many, numbers);
  assert.notEqual(many, numbers);
  assert.ok(Object.is(many[0], -0));
  assert.equal(await fs.readFile(join(directory, 'many.json'), 'utf8'), '[\n  0,\n  1e+21,\n  1e-7,\n  0.000001,\n  9007199254740991,\n  1.25\n]\n');
}));

test('raw UTF16 keys and strings persist as JSON escapes or Unicode without changing output identity', async () => fixture(async directory => {
  const value = { '\ud800': '\udfff', emoji: '雪😀', raw: '\ud800A\udfff', escaped: '\\ud800', zero: -0 };
  const [returned] = await collect((await set(directory, 'A\ud800B', [value])).output);
  assert.equal(returned, value);
  assert.equal(await fs.readFile(join(directory, 'a_b.json'), 'utf8'), '{\n  "\\ud800": "\\udfff",\n  "emoji": "雪😀",\n  "raw": "\\ud800A\\udfff",\n  "escaped": "\\\\ud800",\n  "zero": 0\n}\n');
  const [read] = await collect((await get(directory, 'A\ud800B')).output);
  assert.deepEqual(read, { '\ud800': '\udfff', emoji: '雪😀', raw: '\ud800A\udfff', escaped: '\\ud800', zero: 0 });
  assert.notEqual(read, value);
}));

test('state.get reads during run, ignores input, reconstructs fresh aliases for every read', async () => fixture(async directory => {
  const shared = { value: 1 };
  const value = { left: shared, right: shared };
  await set(directory, 'aliases', [value]);
  let inputReads = 0;
  async function* ignoredInput() { inputReads++; yield 'ignored'; }
  const result = await get(directory, 'aliases', ignoredInput());
  assert.equal(inputReads, 0);
  await fs.writeFile(join(directory, 'aliases.json'), '{"later":2}\n');
  const [read] = await collect(result.output);
  assert.deepEqual(read, { left: { value: 1 }, right: { value: 1 } });
  assert.notEqual(read, value);
  assert.notEqual(read.left, shared);
  assert.notEqual(read.left, read.right);
  const [later1] = await collect((await get(directory, 'aliases')).output);
  const [later2] = await collect((await get(directory, 'aliases')).output);
  assert.deepEqual(later1, { later: 2 });
  assert.deepEqual(later2, { later: 2 });
  assert.notEqual(later1, later2);
  assert.equal(inputReads, 0);
}));

test('exact remembered JSON text restores nested in-process private provenance only as replay', async () => fixture(async directory => {
  const item = mark('call-a', { model: 'fixture', usage: { inputTokens: 2, outputTokens: 3 }, answer: 'ok' });
  const source = { left: item, right: item, array: [item] };
  await set(directory, 'provenance', [source]);
  const [read] = await collect((await get(directory, 'provenance')).output);
  assert.equal(JSON.stringify(read), '{"left":{"model":"fixture","usage":{"inputTokens":2,"outputTokens":3},"answer":"ok"},"right":{"model":"fixture","usage":{"inputTokens":2,"outputTokens":3},"answer":"ok"},"array":[{"model":"fixture","usage":{"inputTokens":2,"outputTokens":3},"answer":"ok"}]}');
  for (const restored of [read.left, read.right, read.array[0]]) {
    assert.deepEqual(llmProvenanceOf(restored), { cacheKey: 'call-a', replayed: true });
    assert.deepEqual(llmProvenanceOf(restored.usage), { cacheKey: 'call-a', replayed: true });
    assert.notEqual(restored, item);
  }
  assert.notEqual(read.left, read.right);
  assert.deepEqual(llmProvenanceOf(item), { cacheKey: 'call-a', replayed: false });
  // Ordinary equivalent external JSON is successful input, but differs in whitespace.
  await fs.writeFile(join(directory, 'provenance.json'), '{"left":{"model":"fixture","usage":{"inputTokens":2,"outputTokens":3},"answer":"ok"},"right":{"model":"fixture","usage":{"inputTokens":2,"outputTokens":3},"answer":"ok"},"array":[{"model":"fixture","usage":{"inputTokens":2,"outputTokens":3},"answer":"ok"}]}\n');
  const [external] = await collect((await get(directory, 'provenance')).output);
  assert.equal(llmProvenanceOf(external.left), null);
  assert.equal(llmProvenanceOf(external.left.usage), null);
}));

test('fresh process preserves persisted public JSON while private LLM marks remain process-local', async () => fixture(async directory => {
  const item = mark('call-fresh', { model: 'fixture', usage: { inputTokens: 2 }, answer: 'ok' });
  await set(directory, 'fresh', [item]);
  assert.deepEqual(await fresh('read', directory, 'fresh'), { items: [{ model: 'fixture', usage: { inputTokens: 2 }, answer: 'ok' }], provenance: null, usageProvenance: null });
}));

test('exactly64 remembered keys and an existing-key rewrite keep latest original provenance', async () => fixture(async directory => {
  // A fresh state.js instance isolates its own 64-entry map; its dependency modules stay original.
  const { stateGetCommand: getter, stateSetCommand: setter } = await import(pathToFileURL(join(root, 'upstream/package/dist/src/commands/stdlib/state.js')).href + '?cache-domain-64');
  for (let index = 0; index < 64; index++) {
    const value = mark('entry-' + index, { model: 'fixture', usage: { inputTokens: 1 }, value: index });
    await setter.run({ input: [value], args: { _: ['entry-' + index] }, ctx: ctx(directory) });
  }
  const replacement = mark('replacement-0', { model: 'fixture', usage: { inputTokens: 4 }, value: 'updated' });
  await setter.run({ input: [replacement], args: { _: ['entry-0'] }, ctx: ctx(directory) });
  for (const [key, expected] of [['entry-0', 'replacement-0'], ['entry-1', 'entry-1'], ['entry-63', 'entry-63']]) {
    const [value] = await collect((await getter.run({ args: { _: [key] }, ctx: ctx(directory) })).output);
    assert.deepEqual(llmProvenanceOf(value), { cacheKey: expected, replayed: true });
  }
  assert.equal((await fs.readdir(directory)).length, 64);
  assert.equal(await fs.readFile(join(directory, 'entry-0.json'), 'utf8'), '{\n  "model": "fixture",\n  "usage": {\n    "inputTokens": 4\n  },\n  "value": "updated"\n}\n');
}));

test('stable comparison sorts nested UTF16 object keys, preserves array order, and normalizes signed zero', () => {
  assert.equal(stableStringify({ z: { b: 2, a: 1 }, a: [{ y: 2, x: 1 }, -0] }), '{"a":[{"x":1,"y":2},0],"z":{"a":1,"b":2}}');
  assert.equal(stableStringify({ '\ue000': 'private', '😀': 'face', '\ud800': 'lead', a: 'plain' }), '{"a":"plain","\\ud800":"lead","😀":"face","\ue000":"private"}');
});

test('diff.last drains and persists at construction; unchanged stable values still replace pretty bytes', async () => fixture(async directory => {
  await fs.writeFile(join(directory, 'snap.json'), '{"b":2,"a":1}\n');
  const entered = deferred(), release = deferred();
  const after = { a: 1, b: 2 };
  async function* input() { yield after; entered.resolve(); await release.promise; }
  const pending = diff(directory, { key: 'snap', _: ['unused'] }, input());
  try { await entered.promise; assert.equal(await fs.readFile(join(directory, 'snap.json'), 'utf8'), '{"b":2,"a":1}\n'); }
  finally { release.resolve(); }
  const result = await pending;
  assert.equal(await fs.readFile(join(directory, 'snap.json'), 'utf8'), '{\n  "a": 1,\n  "b": 2\n}\n');
  await fs.writeFile(join(directory, 'snap.json'), '{"later":true}\n');
  const [snapshot] = await collect(result.output);
  assert.deepEqual(snapshot, { kind: 'diff.last', key: 'snap', changed: false, before: { b: 2, a: 1 }, after: { a: 1, b: 2 } });
  assert.equal(snapshot.after, after);
  assert.notEqual(snapshot.before, after);
}));

test('diff.last successful zero/one/multiple input and before/after identity, scalar and array changes', async () => fixture(async directory => {
  await fs.writeFile(join(directory, 'zero.json'), '[]\n');
  assert.deepEqual(await collect((await diff(directory, { _: ['zero'] }, [])).output), [{ kind: 'diff.last', key: 'zero', changed: false, before: [], after: [] }]);
  await fs.writeFile(join(directory, 'one.json'), '{"a":[1,2],"n":0}\n');
  const after = { n: -0, a: [2, 1] };
  const [one] = await collect((await diff(directory, { key: 'one', _: [] }, [after])).output);
  assert.deepEqual(one, { kind: 'diff.last', key: 'one', changed: true, before: { a: [1, 2], n: 0 }, after: { n: -0, a: [2, 1] } });
  assert.equal(one.after, after);
  assert.ok(Object.is(one.after.n, -0));
  await fs.writeFile(join(directory, 'multiple.json'), '[1,2]\n');
  const object = { x: 3 };
  const [multiple] = await collect((await diff(directory, { key: 'multiple', _: [] }, [1, object])).output);
  assert.deepEqual(multiple, { kind: 'diff.last', key: 'multiple', changed: true, before: [1, 2], after: [1, { x: 3 }] });
  assert.equal(multiple.after[1], object);
  assert.equal(await fs.readFile(join(directory, 'multiple.json'), 'utf8'), '[\n  1,\n  {\n    "x": 3\n  }\n]\n');
}));

test('actual lock owner, original store reads, atomic write, and diff afterStore operate under real filesystem locks', async () => fixture(async directory => {
  const env = ctx(directory).env;
  await fs.writeFile(join(directory, 'locked.json'), '{"v":1}\n');
  const value = await withFileLock({ filePath: join(directory, 'locked.json'), task: async () => {
    assert.match(await fs.readFile(join(directory, 'locked.json.lock/owner'), 'utf8'), new RegExp('^' + process.pid + ':[^:]*:[a-f0-9]{12}\\n$'));
    return readStateJson({ env, key: 'locked' });
  } });
  assert.deepEqual(value, { v: 1 });
  await writeStateJson({ env, key: 'locked', value: { v: 2 } });
  assert.equal(await fs.readFile(join(directory, 'locked.json'), 'utf8'), '{\n  "v": 2\n}\n');
  const after = { v: 3 };
  let calls = 0;
  const snapshot = await diffAndStore({ env, key: 'locked', value: after, afterStore: async received => {
    calls++;
    assert.deepEqual(received, { before: { v: 2 }, after: { v: 3 }, changed: true });
    assert.equal(received.after, after);
    assert.deepEqual(await readStateJson({ env, key: 'locked' }), { v: 3 });
    assert.match(await fs.readFile(join(directory, 'locked.json.lock/owner'), 'utf8'), new RegExp('^' + process.pid + ':'));
  } });
  assert.equal(calls, 1);
  assert.equal(snapshot.after, after);
  assert.deepEqual(await fs.readdir(directory), ['locked.json']);
}));

test('diff.last publishes matching JSON without replacing earlier state.set private provenance memory', async () => fixture(async directory => {
  const original = mark('original-call', { model: 'fixture', usage: { inputTokens: 2 }, answer: 'ok' });
  await set(directory, 'retained', [original]);
  const after = { model: 'fixture', usage: { inputTokens: 2 }, answer: 'ok' };
  const [snapshot] = await collect((await diff(directory, { key: 'retained', _: [] }, [after])).output);
  assert.equal(snapshot.changed, false);
  assert.equal(llmProvenanceOf(snapshot.before), null);
  assert.equal(snapshot.after, after);
  const [reread] = await collect((await get(directory, 'retained')).output);
  assert.deepEqual(llmProvenanceOf(reread), { cacheKey: 'original-call', replayed: true });
}));

for (const mode of ['same_stage', 'next_stage']) test('fresh original runtime resumes ordinary ' + mode + ' checkpoint with state and diff writes', async () => fixture(async directory => {
  await fs.writeFile(join(directory, 'initial.json'), '{"draft":"ready"}\n');
  await fs.writeFile(join(directory, 'baseline_diff.json'), '{"decision":"old"}\n');
  const paused = await fresh('start', directory, mode);
  assert.equal(paused.status, 'needs_input');
  assert.deepEqual(paused.request, { prompt: 'Continue?', responseSchema: { type: 'object', properties: { decision: { type: 'string' } }, required: ['decision'] } });
  assert.equal(paused.snapshot.resumeMode, mode);
  assert.equal(paused.snapshot.resumeAtIndex, mode === 'same_stage' ? 2 : 3);
  assert.equal(paused.snapshot.haltType, 'input_request');
  assert.deepEqual(paused.snapshot.items, []);
  if (mode === 'same_stage') assert.deepEqual(paused.snapshot.commandInput, { pending: { requestIndex: 0, metadata: { prompt: 'Continue?', responseSchema: { type: 'object', properties: { decision: { type: 'string' } }, required: ['decision'] }, signature: '{"prompt":"Continue?","responseSchema":{"properties":{"decision":{"type":"string"}},"required":["decision"],"type":"object"}}' }, suspendedState: { type: 'ask' } }, history: [] });
  else assert.equal(paused.snapshot.commandInput, undefined);
  assert.equal(await fs.readFile(join(directory, 'before_checkpoint.json'), 'utf8'), '{\n  "draft": "ready"\n}\n');
  const resumed = await fresh('resume', directory, paused.stateKey);
  assert.deepEqual(resumed.finalized, { status: 'ok', output: [{ kind: 'diff.last', key: 'baseline_diff', changed: true, before: { decision: 'old' }, after: { decision: 'approve' } }], requiresApproval: null, requiresInput: null });
  assert.equal(resumed.consumed, true);
  assert.deepEqual(resumed.files, ['baseline_diff.json', 'before_checkpoint.json', 'initial.json', 'reply.json']);
  assert.equal(resumed.replyBytes, '{\n  "decision": "approve"\n}\n');
  assert.equal(resumed.diffBytes, '{\n  "decision": "approve"\n}\n');
}));

test('valid JSON numeric overflow and underflow retain original parse semantics and successful JSON writes', async () => fixture(async directory => {
  await fs.writeFile(join(directory, 'positive.json'), '1e400\n');
  await fs.writeFile(join(directory, 'negative.json'), '-1e400\n');
  await fs.writeFile(join(directory, 'nested.json'), '{"positive":1e400,"negative":-1e400,"tiny":1e-4000,"negativeTiny":-1e-4000,"negativeZero":-0}\n');
  assert.equal((await collect((await get(directory, 'positive')).output))[0], Infinity);
  assert.equal((await collect((await get(directory, 'negative')).output))[0], -Infinity);
  const [nested] = await collect((await get(directory, 'nested')).output);
  assert.equal(nested.positive, Infinity);
  assert.equal(nested.negative, -Infinity);
  assert.ok(Object.is(nested.tiny, 0));
  assert.ok(Object.is(nested.negativeTiny, -0));
  assert.ok(Object.is(nested.negativeZero, -0));
  assert.equal(JSON.stringify(nested), '{"positive":null,"negative":null,"tiny":0,"negativeTiny":0,"negativeZero":0}');
  assert.equal((await collect((await set(directory, 'roundtrip', [nested])).output))[0], nested);
  assert.equal(await fs.readFile(join(directory, 'roundtrip.json'), 'utf8'), '{\n  "positive": null,\n  "negative": null,\n  "tiny": 0,\n  "negativeTiny": 0,\n  "negativeZero": 0\n}\n');
  const [reread] = await collect((await get(directory, 'roundtrip')).output);
  assert.deepEqual(reread, { positive: null, negative: null, tiny: 0, negativeTiny: 0, negativeZero: 0 });
  await fs.writeFile(join(directory, 'overflow_diff.json'), '{"number":1e400}\n');
  const [snapshot] = await collect((await diff(directory, { key: 'overflow_diff', _: [] }, [{ number: null }])).output);
  assert.equal(snapshot.changed, false);
  assert.equal(snapshot.before.number, Infinity);
  assert.equal(snapshot.after.number, null);
  assert.equal(await fs.readFile(join(directory, 'overflow_diff.json'), 'utf8'), '{\n  "number": null\n}\n');
}));
