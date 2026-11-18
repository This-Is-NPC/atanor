# Changelog

## [0.6.0](https://github.com/This-Is-NPC/atanor/compare/v0.5.0...v0.6.0) (2026-11-18)


### Features

* **load:** judge each scale load on its own ([0bd735c](https://github.com/This-Is-NPC/atanor/commit/0bd735c4c8b10907194cd7621568936a5fd83b99))
* **telemetry:** time cell wakes ([209d5ef](https://github.com/This-Is-NPC/atanor/commit/209d5effd8f7f5400701b772f8572341e7a03574))


### Bug Fixes

* **build:** keep priv so a cached NIF loads ([6575968](https://github.com/This-Is-NPC/atanor/commit/65759683aa02577101bc280562a7f3b2eb21c2d0))


### Performance Improvements

* **jobs:** rearm inside the claim transaction ([98867c4](https://github.com/This-Is-NPC/atanor/commit/98867c4883a06f01f49f06f35e56d432543e7ca3))
* **load:** add the 025 node-join round ([61e2831](https://github.com/This-Is-NPC/atanor/commit/61e2831dc6e3cb40f0a9b18d5223cf81b514cc46))

## [0.5.0](https://github.com/This-Is-NPC/atanor/compare/v0.4.1...v0.5.0) (2026-11-18)


### Features

* **daemon:** add operator consent settings ([a0823da](https://github.com/This-Is-NPC/atanor/commit/a0823da2f331b1fc53a69c1416f242867a234d95))
* **http:** declare a TLS proxy, warn on clear listeners ([5e0a059](https://github.com/This-Is-NPC/atanor/commit/5e0a05941b7a020c7812f3902e7442e6219c70d4))
* **telemetry:** count release compaction outcomes ([97bad64](https://github.com/This-Is-NPC/atanor/commit/97bad640e5ae1c458f25b86da2f8a17c5e9f70c0))


### Bug Fixes

* **admin:** give error bodies fixed reasons ([3c44321](https://github.com/This-Is-NPC/atanor/commit/3c443210f0e1f11281d8fd263476c7d649634c9c))
* **cli:** refuse login when stty fails ([b2b6f1a](https://github.com/This-Is-NPC/atanor/commit/b2b6f1aa213ecd52407e6baae64bc625cfbf2be4))
* **deps:** bump plug past a multipart advisory ([ff0ad9f](https://github.com/This-Is-NPC/atanor/commit/ff0ad9f83dd0c9f357f19ed52a7343fbb5fa71f5))
* **http:** name refused wakes awake_limit ([ae11aa6](https://github.com/This-Is-NPC/atanor/commit/ae11aa685893cb53a64b8cac66b6ed56e2a5f409))
* **tls:** hide key bytes, warn on cert validity ([1553c6a](https://github.com/This-Is-NPC/atanor/commit/1553c6a8fadd88821fe0abb7597b1ce209f2dfd0))
* **wasm:** escape guest stderr before logging ([bc40671](https://github.com/This-Is-NPC/atanor/commit/bc406712b955cfadae1f1c65e7d6f443edbd6131))
* **ws:** turn compression off, add allowed origins ([8eedb10](https://github.com/This-Is-NPC/atanor/commit/8eedb104db51fdd9e8ba84eaf88cb46781951812))


### Performance Improvements

* **build:** share the cargo target, cache the NIF ([39c153a](https://github.com/This-Is-NPC/atanor/commit/39c153af31f555fc45c1f5fa472fc6eb1489415b))

## [0.4.1](https://github.com/This-Is-NPC/atanor/compare/v0.4.0...v0.4.1) (2026-11-18)


### Bug Fixes

* **readme:** undo the release version replace ([9ec7cbb](https://github.com/This-Is-NPC/atanor/commit/9ec7cbb4400c65ae5b8992e04ebe387a2437aa1c))

## [0.4.0](https://github.com/This-Is-NPC/atanor/compare/v0.3.0...v0.4.0) (2026-11-18)


### ⚠ BREAKING CHANGES

* **daemon:** ATANOR_PEERS and AtanorDaemon.Mesh are removed. The daemon publishes atanor@<ATANOR_ADVERTISE> in the registry; new keys ATANOR_GROUP, ATANOR_REGISTRY_TTL_MS and ATANOR_REGISTRY_RENEW_MS.
* **deps:** restore: [prefetch_bytes:] is refused; use

### Features

* **admin:** sample what grows in a node's memory ([842557a](https://github.com/This-Is-NPC/atanor/commit/842557a8b9b5a7963b5ddbbd32ba2bd486abe65a))
* **admin:** show admission counters in /runtime ([f648be5](https://github.com/This-Is-NPC/atanor/commit/f648be5a212c93e1b8b4e32f1d721f211f1f7d50))
* **admin:** show the store breaker on health ([e0b5591](https://github.com/This-Is-NPC/atanor/commit/e0b559148bd14ea01d9b228eea962c76284fb9f0))
* **cli:** deploy a WASM worker through the bucket ([e055067](https://github.com/This-Is-NPC/atanor/commit/e0550671ac9d3caf8e17184f605ff8a4234dfae9))
* **cluster:** add a native load worker and store metrics ([797f15a](https://github.com/This-Is-NPC/atanor/commit/797f15a2dcb06a9f8f416cd3354c34f3da4aed18))
* **cluster:** configure the node with Atanor.Daemon ([47fb609](https://github.com/This-Is-NPC/atanor/commit/47fb609e6d946e8e730d31827c0be3a013ce1449))
* **cluster:** form the cluster through the store ([bdbc94f](https://github.com/This-Is-NPC/atanor/commit/bdbc94fb3450c20578f98f1d4b894a31f666bf47))
* **cluster:** rebalance awake cells on node join ([b60e1e7](https://github.com/This-Is-NPC/atanor/commit/b60e1e75320ee3d1a0ba560a5fbddb84c40b93e2))
* **config:** accept the release compaction options ([be74b3f](https://github.com/This-Is-NPC/atanor/commit/be74b3f267075d185bdccd773f90f60757d1be34))
* **daemon:** add a store builder for s3 URLs ([0dd4b51](https://github.com/This-Is-NPC/atanor/commit/0dd4b5101a85771a621487b843b09af8e9c9aeb6))
* **daemon:** add ATANOR_HTTP_MAX_CONNECTIONS ([70c0f20](https://github.com/This-Is-NPC/atanor/commit/70c0f203b717568306a26141d30fbe84e487e401))
* **daemon:** add the AWS credential chain ([8024031](https://github.com/This-Is-NPC/atanor/commit/8024031c652a2c4541217f66e4ce505014cc0b82))
* **daemon:** expose the processes of a node ([a859b82](https://github.com/This-Is-NPC/atanor/commit/a859b8285a3310b80eeaff0243c104aa65e27b6c))
* **daemon:** find nodes through the store ([69b1963](https://github.com/This-Is-NPC/atanor/commit/69b19639416f58968f46ae6cbc15f5fe72adc04e))
* **daemon:** load node settings from env and file ([f2ed772](https://github.com/This-Is-NPC/atanor/commit/f2ed77248d584a2bfeee7b65b16a6b23630476b9))
* **deps:** pin alambique v0.5.0 ([7c4d755](https://github.com/This-Is-NPC/atanor/commit/7c4d755db19929841a3c1f41d83cbd149ee7daa0))
* **dev:** publish dev nodes in the bucket ([1f37242](https://github.com/This-Is-NPC/atanor/commit/1f37242c614b7598ff8c0676fffedc189b482791))
* **diagnostics:** cap pending crash reports by size ([9074401](https://github.com/This-Is-NPC/atanor/commit/9074401923403dc7c959e33196b46279b11f318f))
* **discovery:** connect to the nodes in the registry ([147bb44](https://github.com/This-Is-NPC/atanor/commit/147bb44bc2315493e18decaff7a5e6633f81e9ff))
* **disk:** bound data_dir with a node disk budget ([5a79930](https://github.com/This-Is-NPC/atanor/commit/5a7993059ee4a15f7a959e452a6b2e8a9691bd7d))
* **examples:** add a Phoenix and LiveView app ([c6ac57f](https://github.com/This-Is-NPC/atanor/commit/c6ac57f82ba8df690bafb29fe9b508d8d1091ee3))
* **http:** name the gate behind a 503 overloaded ([57fc848](https://github.com/This-Is-NPC/atanor/commit/57fc84844af9d6389101dea1f0654db3c7f7e2a1))
* **http:** refuse with 503 before the node dies ([b299057](https://github.com/This-Is-NPC/atanor/commit/b299057b5287f24207023d80a69e2d527481efb3))
* **load:** add a disk-backed store option ([e91387e](https://github.com/This-Is-NPC/atanor/commit/e91387e193ac10e620f94d5819a892e6918da680))
* **load:** add a plain wasm lab worker ([388eedd](https://github.com/This-Is-NPC/atanor/commit/388eedd3d544ddb61226da7d272bcfd843294cfa))
* **load:** add cases, store overrides, ceiling plans ([535fff9](https://github.com/This-Is-NPC/atanor/commit/535fff9ae176b5928eaa978528a42b78d87c8385))
* **load:** add the load-test harness and tasks ([139beed](https://github.com/This-Is-NPC/atanor/commit/139beed36ab711ea95a6b34b74362e76491af250))
* **load:** add the scale measure ([33a5308](https://github.com/This-Is-NPC/atanor/commit/33a5308ef01b1f9fbe7c917bb4832a84a4412585))
* **load:** fail a step that refuses over 1% ([1d21679](https://github.com/This-Is-NPC/atanor/commit/1d21679368dbda9603d6d8e6ce2e013d05f853d3))
* **load:** keep the store evidence of a failed step ([c1d46af](https://github.com/This-Is-NPC/atanor/commit/c1d46af055bfffa98fb35f37dadf6e63742e8fea))
* **load:** mark a stalled step invalid ([2250877](https://github.com/This-Is-NPC/atanor/commit/22508778c6291a107881836a4a05b332da04b535))
* **load:** read and validate a round config ([af0fc50](https://github.com/This-Is-NPC/atanor/commit/af0fc50f2e1897cfa76f096dfb58aa7f666c716e))
* **load:** read the pressure hibernation count ([0f7b938](https://github.com/This-Is-NPC/atanor/commit/0f7b93863a59a0028b791a7aca4c2c5e1ece5fd1))
* **load:** record admission and store per sample ([880ece2](https://github.com/This-Is-NPC/atanor/commit/880ece24d45ef0c0ce021bb310cf1a2760b08c6f))
* **load:** record node, refusal and eviction evidence ([a501c9c](https://github.com/This-Is-NPC/atanor/commit/a501c9c2b22973e682bbebda234956921ddde8df))
* **load:** refine on a fresh node after a fail ([b414190](https://github.com/This-Is-NPC/atanor/commit/b414190c84c369aba65a697fdffd6c873e557b68))
* **load:** refuse swap and record host swap ([86e57c6](https://github.com/This-Is-NPC/atanor/commit/86e57c68d9890e85286215bdf9a3dbbced35d66d))
* **load:** run a round from a config file ([232849a](https://github.com/This-Is-NPC/atanor/commit/232849ac8bbc7c5b44ebab77f00e45a16806ec39))
* **load:** run a round on a remote host ([4f4c0e2](https://github.com/This-Is-NPC/atanor/commit/4f4c0e24cc4f139025845130c1d96d7c60fc9712))
* **load:** skip steps done, nested result layout ([ac938ae](https://github.com/This-Is-NPC/atanor/commit/ac938ae08531e5471fdf31bbfd5661ea26fa03f0))
* **load:** tie swap timeouts to a node and log drain ([a765a29](https://github.com/This-Is-NPC/atanor/commit/a765a2996f7f81543f49e7e45fc84af389bc0acf))
* **load:** wait for a quiet host and stop on contamination ([1a77280](https://github.com/This-Is-NPC/atanor/commit/1a77280511fe837e107709442473f182b7221916))
* **load:** warm up the cells of an http step ([9e510a5](https://github.com/This-Is-NPC/atanor/commit/9e510a5a2fd6d653913a6c1f3f71482bd6b524fc))
* **memory:** hibernate idle cells under pressure ([3af8075](https://github.com/This-Is-NPC/atanor/commit/3af807582ff532818d79b4533405d8456023a349))
* **release:** add mix atanor.release ([0877239](https://github.com/This-Is-NPC/atanor/commit/0877239ad38526e7d396eac99692162ae17744d2))
* **release:** run the CLI from the release image ([a1c1fde](https://github.com/This-Is-NPC/atanor/commit/a1c1fde3decaa5ea757a36688c72f4ead62c460c))
* **runtime:** count cell wakes ([b6101fc](https://github.com/This-Is-NPC/atanor/commit/b6101fcdc72746cd427729154022a4eff42ec42e))
* **store:** log the breaker and the store errors behind it ([3af0020](https://github.com/This-Is-NPC/atanor/commit/3af002051465a8649dd760eaccb66a0c72383727))
* **store:** log the kind and detail of a crash ([86829fb](https://github.com/This-Is-NPC/atanor/commit/86829fbf007ffa829a70923826c58eadbd614de8))
* **store:** log the reason of each store failure ([89a714e](https://github.com/This-Is-NPC/atanor/commit/89a714eed89f4eed41ba7966e189dde17c7101cc))
* **wake:** log wakes slower than a second ([36deb84](https://github.com/This-Is-NPC/atanor/commit/36deb84a301d4ebbaa358d85f98b31be9bd2ae0f))


### Bug Fixes

* **admin:** fill the top processes past dead ones ([dc5f34b](https://github.com/This-Is-NPC/atanor/commit/dc5f34b878867c10a02b0cdaedb412ca5521fd4d))
* **admission:** count every overload 503 in refused ([bf2aa8d](https://github.com/This-Is-NPC/atanor/commit/bf2aa8d6ec2b1ca0e75d6c14e5f8b905353f2010))
* **admission:** report null refuse_at without a gate ([26dcd10](https://github.com/This-Is-NPC/atanor/commit/26dcd10bb54de838d112a00eac415bc7474020d6))
* **cell:** refuse cold wakes over the memory mark ([9c33125](https://github.com/This-Is-NPC/atanor/commit/9c3312500d1a39d9ed7c460a681f794e45ec96ad))
* **cell:** serve cells owned by another node ([53d4e60](https://github.com/This-Is-NPC/atanor/commit/53d4e6015a07a0ddcd292b40f1b680fd59a5e138))
* **cell:** touch a cell before a write that may queue ([3e0250d](https://github.com/This-Is-NPC/atanor/commit/3e0250dc39291f94b42d89779cff0a53a7512a89))
* **cell:** touch only a waking cell before a write ([e23f6a2](https://github.com/This-Is-NPC/atanor/commit/e23f6a21546507ed72c5c45ad9cb207502b9ffad))
* **cell:** wake a cold cell apart, call in caller ([6cfcdfe](https://github.com/This-Is-NPC/atanor/commit/6cfcdfe76feaee03debee804c1c5a095b837b28b))
* **check:** keep the full gate output in a log ([b5aea70](https://github.com/This-Is-NPC/atanor/commit/b5aea7055f8a3bf114f9de73389ef6fb302cbef9))
* **cli:** hide the token on a dumb terminal ([d8bb995](https://github.com/This-Is-NPC/atanor/commit/d8bb995d71893b1df0ca8e7026f32dae9824710c))
* **cluster:** add the dashboard deps to the load node ([9c6faf2](https://github.com/This-Is-NPC/atanor/commit/9c6faf21a3c76c7f75e1615ea1377a7ff5e58ea0))
* **cluster:** forbid swap in measured containers ([f7673fa](https://github.com/This-Is-NPC/atanor/commit/f7673faba8b9a2bd854e5493b571c83e5eb369d5))
* **cluster:** give nodes dotted names and a safe cookie ([de2cd76](https://github.com/This-Is-NPC/atanor/commit/de2cd7699b7644788f8e031a483d9a3822cf1c2e))
* **cluster:** keep load results out of the image ([9d506de](https://github.com/This-Is-NPC/atanor/commit/9d506de7db34810ab784f331077a04449159c15f))
* **coverage:** drop stale Rust test binaries ([362ae9f](https://github.com/This-Is-NPC/atanor/commit/362ae9f139eb3d609ae65bcb1e656b0a0ec29134))
* **daemon:** name the right entrypoint test ([d72faaa](https://github.com/This-Is-NPC/atanor/commit/d72faaa7810fa67de784540c1ddec1f9f2f9428c))
* **dashboard:** keep secrets out of reports and pages ([223867a](https://github.com/This-Is-NPC/atanor/commit/223867a629cb5fc447f931ec47680e24bb523fcf))
* **deps:** pin Alambique v0.9.0 ([6cefe7e](https://github.com/This-Is-NPC/atanor/commit/6cefe7ee36a69e734a6aca0041a2c3c0968767f2))
* **dispatch:** name an unknown owner, not a fence ([d6d888f](https://github.com/This-Is-NPC/atanor/commit/d6d888f6e0325f78ad36e83719e34dc6666a8a2e))
* **docs:** repair the clean-machine install path ([42f84eb](https://github.com/This-Is-NPC/atanor/commit/42f84eb7f25895daef2510230ab68c0f191e56f0))
* **http:** answer 503 queue_timeout past a wait deadline ([2700bc4](https://github.com/This-Is-NPC/atanor/commit/2700bc47dcd89252fb40bdfe5575a682e41fd0f4))
* **http:** answer 503 when a write finds the disk full ([72e2107](https://github.com/This-Is-NPC/atanor/commit/72e2107fac4cc58c47432b0d204b306fa0299011))
* **http:** bound slow headers and bodies by deadline ([00b1c20](https://github.com/This-Is-NPC/atanor/commit/00b1c205c7089c14a53151906b723b1570f8b049))
* **http:** count every 503 by reason ([f8db29f](https://github.com/This-Is-NPC/atanor/commit/f8db29fdab6f93d5ecb72765cea081ba8b7a53f4))
* **jobs:** classify infrastructure errors by their source ([e8c661e](https://github.com/This-Is-NPC/atanor/commit/e8c661e4e79938aa94607c52a4787f80fde55892))
* **jobs:** count a guest error as a handler failure ([9ada536](https://github.com/This-Is-NPC/atanor/commit/9ada5364ec426687012fa490397da7b52647de35))
* **jobs:** do not count infrastructure errors as attempts ([91e1688](https://github.com/This-Is-NPC/atanor/commit/91e16880e95b8262087f7b181971621ae13c966f))
* **jobs:** grow the infrastructure delay, count cell timeouts ([23f4387](https://github.com/This-Is-NPC/atanor/commit/23f4387a6e146a66a62ed7af15ebf26ed2d33379))
* **jobs:** keep a dead job until its index delete works ([a3ccaea](https://github.com/This-Is-NPC/atanor/commit/a3ccaea5c25fd78c1a5fbdecf6ff7bafee84ff86))
* **jobs:** match the error a handler returns to the call's ([cdf4031](https://github.com/This-Is-NPC/atanor/commit/cdf4031990177512855b934a13fa25cbb763770e))
* **jobs:** put back a missing wake index object ([b384610](https://github.com/This-Is-NPC/atanor/commit/b3846105513eb26eeda454a563a30e3fa5149da9))
* **load:** add the tmpfs on top of the scenario memory ([884444f](https://github.com/This-Is-NPC/atanor/commit/884444fdab8f0452b7dfaa958e18fa3be30e0841))
* **load:** check swap only on measured containers ([96c3646](https://github.com/This-Is-NPC/atanor/commit/96c3646f9b0aa2e80d1b121061891ebadea32ece))
* **load:** discard both bodies in the store rtt ([ee15cc0](https://github.com/This-Is-NPC/atanor/commit/ee15cc0e708b6faf294336da9c260cedfb62562a))
* **load:** end the round when the node stops ([418fa63](https://github.com/This-Is-NPC/atanor/commit/418fa63aa3c43737b7438d5c040d37463effed90))
* **load:** fail a step the store stalls twice ([f853a15](https://github.com/This-Is-NPC/atanor/commit/f853a15094aa5bdafdb2cac303e43228a92c65fa))
* **load:** give the node the scenario memory as limit ([3be7218](https://github.com/This-Is-NPC/atanor/commit/3be7218b61e1552bbc22d2266457dfe67c6b23bd))
* **load:** judge a stall on the generator's own lag ([e710446](https://github.com/This-Is-NPC/atanor/commit/e710446313f5a74e91a31840d9362008e02a1dc4))
* **load:** judge a stopped node instead of crashing ([a89e5b6](https://github.com/This-Is-NPC/atanor/commit/a89e5b6a12ecf91f038fd87b83a2dea4622596aa))
* **load:** judge host swap by growth per step ([fa8d5a7](https://github.com/This-Is-NPC/atanor/commit/fa8d5a7817e4c7548f9e10ac729017fe41413993))
* **load:** judge store stalls, node budgets, 503 reasons ([3e32ed0](https://github.com/This-Is-NPC/atanor/commit/3e32ed0a7607f09055cc6860c559d93776baeacf))
* **load:** judge swap by generator and containers ([734e012](https://github.com/This-Is-NPC/atanor/commit/734e0126a19e5ae725e78c4de2c2e9ace97d680f))
* **load:** judge the harness limits of the lab ([1c91331](https://github.com/This-Is-NPC/atanor/commit/1c913316f384649563d904500e8a83c7f0e2b29b))
* **load:** let load:up rerun on a running cluster ([463a70e](https://github.com/This-Is-NPC/atanor/commit/463a70eeb65fcdbb23368e57712bcdfddabdc628))
* **load:** measure a saturated step instead of failing ([a796d6a](https://github.com/This-Is-NPC/atanor/commit/a796d6a6cd23eb46de6dd2a39cce75c935d805f8))
* **load:** read the join rebalance at the window end ([b6eb173](https://github.com/This-Is-NPC/atanor/commit/b6eb173bef9c50cab9e3fa3d2533db942d0e9bc4))
* **load:** size the node data dir for scenario B ([b74630d](https://github.com/This-Is-NPC/atanor/commit/b74630d9c36023f01e2e230b09f9d9028f65a0b4))
* **load:** skip intervals with a missing CPU reading ([b453111](https://github.com/This-Is-NPC/atanor/commit/b453111d26f40e97a8e56912d81f8721ed8140a6))
* **load:** start swap node B from the load image ([fe2527c](https://github.com/This-Is-NPC/atanor/commit/fe2527cd4d68f71a972bb7002e1b271e48327a6e))
* **load:** stop when the store tmpfs is full ([2192e09](https://github.com/This-Is-NPC/atanor/commit/2192e0989a0c28d2ad655097093ef78790cd80d3))
* **load:** use the swap round's info in swap ([8157e47](https://github.com/This-Is-NPC/atanor/commit/8157e472f4a4b457f892ffad045d14087e994577))
* **load:** warn on CPU caps and judge busy in the join ([6d07d53](https://github.com/This-Is-NPC/atanor/commit/6d07d53c0140a5e211f7df997e59b6c7b447dcef))
* **memory:** bound wakes by the node's memory budget ([e3c9f07](https://github.com/This-Is-NPC/atanor/commit/e3c9f073d2b6d51e02bc6f990e28b6d0e9d33b7e))
* **memory:** derive wakes from the 0.5 wake cost ([d8774b3](https://github.com/This-Is-NPC/atanor/commit/d8774b3cb85ceff0b2ef8082ea1f9ffee1032390))
* **memory:** leave fetch_concurrency to Alambique ([4217e4f](https://github.com/This-Is-NPC/atanor/commit/4217e4f727e93891456aa197be9c82f79ce97e3a))
* **memory:** size awake cells from the boot baseline ([14c6de8](https://github.com/This-Is-NPC/atanor/commit/14c6de8263bf778abc88b9be83ce418d16024bb3))
* **ops:** hand the derived grace to Compose ([56b7562](https://github.com/This-Is-NPC/atanor/commit/56b7562697bb44920a58bba1f88f6a2ffb3ed574))
* **ops:** stop nodes after the drain, not during it ([1c069f2](https://github.com/This-Is-NPC/atanor/commit/1c069f2760de72480a1ca27e552d4550ff2edae5))
* **rebalance:** do not pin a cell a rebalance moved ([ed9ef02](https://github.com/This-Is-NPC/atanor/commit/ed9ef02596cd1e2e4d068485814f269f06c3176a))
* **rebalance:** emit no move event for a busy cell ([5c3ac3c](https://github.com/This-Is-NPC/atanor/commit/5c3ac3cf82570311e992091ba9694a6682efcd55))
* **takeover:** keep a lost peer owner_unreachable ([b114b17](https://github.com/This-Is-NPC/atanor/commit/b114b17ae68984415a4e3977a9d7f85d4215c319))
* **tls:** read the pair signature before loading it ([a76f2f2](https://github.com/This-Is-NPC/atanor/commit/a76f2f21e552929a1d32075f27d6980faa11d9e9))
* **unavailable:** map disk_full and store breaker ([4e4bfd6](https://github.com/This-Is-NPC/atanor/commit/4e4bfd6203d9eca4a43071b714192ecdd4627063))
* **wasm:** authenticate the compile cache with a key ([a79decf](https://github.com/This-Is-NPC/atanor/commit/a79decf8247d32787621c93e170b5df4bbec9d64))
* **wasm:** derive waiting guests and queue from memory ([8d58e59](https://github.com/This-Is-NPC/atanor/commit/8d58e59dfcdcf1cb833feccf5f3ca40b05b60959))
* **wasm:** free the call slot of a waiting guest ([257e17f](https://github.com/This-Is-NPC/atanor/commit/257e17fedcac37974ee992ef247efbeac16f682c))
* **wasm:** size the pool by the container CPU quota ([232100f](https://github.com/This-Is-NPC/atanor/commit/232100f0b4a70ec5b4d9d1faf3d21a088466daa3))
* **wasm:** take a worker slot when a call starts ([250113e](https://github.com/This-Is-NPC/atanor/commit/250113e5565e3caea21b776a8eb3046fcb2899df))

## [0.3.0](https://github.com/This-Is-NPC/atanor/compare/v0.2.0...v0.3.0) (2026-11-11)


### Features

* **config:** accept the new alambique limit keys ([f8269ef](https://github.com/This-Is-NPC/atanor/commit/f8269ef873cc2c59fdc17a86ffadf0d7fc380d9f))


### Bug Fixes

* **admin:** limit failed token attempts per address ([a07c09c](https://github.com/This-Is-NPC/atanor/commit/a07c09cd3dcd7f8ed15b3bf5aa730709bed4f8b6))
* **detector:** hear a peer through bytes on a busy link ([94d0299](https://github.com/This-Is-NPC/atanor/commit/94d02996c0cd1896a77563fed3acc44bdd3bc6ab))
* **env:** pin nested worker calls to one deployment ([d79a18d](https://github.com/This-Is-NPC/atanor/commit/d79a18dde0403387cd8dde968284472dc2e3fcfb))
* **feed:** report a feed read timeout as a store error ([5d333aa](https://github.com/This-Is-NPC/atanor/commit/5d333aa6fb3dcf7185e3caa831dfc6d14e80abbb))
* **start:** log why a data_dir is refused ([ab6522e](https://github.com/This-Is-NPC/atanor/commit/ab6522eb6730efde835a3365c8a15c74330650f0))
* **sweeps:** page the undo table hash ([4579ffc](https://github.com/This-Is-NPC/atanor/commit/4579ffccab3673fe4c0433c50149a54289683811))
* **sweeps:** read undo tables without a row cursor ([d762fe4](https://github.com/This-Is-NPC/atanor/commit/d762fe4b9df80e7e271c4fd7408a241ee928c28c))
* **takeover:** rate-limit no_quorum events ([46598fc](https://github.com/This-Is-NPC/atanor/commit/46598fc4b301c28eaf9b521c9277fa126dc3b4c4))
* **wasm:** cap batch results and cell messages ([40a55b0](https://github.com/This-Is-NPC/atanor/commit/40a55b03a6fb8517cbb4d694c0a0783fb4d255ab))
* **wasm:** compile off the dirty schedulers ([7d62aaa](https://github.com/This-Is-NPC/atanor/commit/7d62aaa14bd885eaf29069c43a1e135957bf6626))
* **wasm:** decode large host replies on a dirty nif ([2fca06c](https://github.com/This-Is-NPC/atanor/commit/2fca06cd4c6c4234e016e429828bae65bf15f756))
* **wasm:** free the right to run while a guest waits ([36dc2e5](https://github.com/This-Is-NPC/atanor/commit/36dc2e59215e8b6154a8298b2f0af3817a38c9b3))
* **wasm:** name the settings when pooling fails ([623c5e5](https://github.com/This-Is-NPC/atanor/commit/623c5e5f9abe9e97e622dfb79ebf66afb2c8e432))


### Performance Improvements

* **env:** pin ids of nested callees, not deployments ([dc92858](https://github.com/This-Is-NPC/atanor/commit/dc928589515cd3ea33b4d9da2deecf3a3e9531c3))
* **wasm:** wake one idle pool thread per job ([3c15a15](https://github.com/This-Is-NPC/atanor/commit/3c15a15c0f2b4d730ea866ce113a4dd568572d14))

## [0.2.0](https://github.com/This-Is-NPC/atanor/compare/v0.1.0...v0.2.0) (2026-11-11)


### Features

* **auth:** flush the OIDC key cache from the admin API ([dce59ab](https://github.com/This-Is-NPC/atanor/commit/dce59ab2de7c97c886f6db02c94c0afd614a78fa))
* **cluster:** allow nodes with no peers ([4d95753](https://github.com/This-Is-NPC/atanor/commit/4d95753fa58ccdbe4e0a3d0c4dd556b2637b3c63))
* **drain:** drain a node on demand or on sigterm ([ef82294](https://github.com/This-Is-NPC/atanor/commit/ef822945b612b81d5be3781eda653e563fe08cbc))
* **drain:** report the progress of a running drain ([767379a](https://github.com/This-Is-NPC/atanor/commit/767379a2cda1b975cc3aeece75236358aea87da7))
* **http:** answer draining and held_elsewhere 503s ([e49991c](https://github.com/This-Is-NPC/atanor/commit/e49991c159a914a189d98efa64aa294204aea384))
* **jobs:** release claims when a node drains ([ca040db](https://github.com/This-Is-NPC/atanor/commit/ca040dbb7e90ff91f897c9950aa5a8cb873f4a01))


### Bug Fixes

* **cli:** read the login token without echo ([4ad86af](https://github.com/This-Is-NPC/atanor/commit/4ad86afed23a8be26f7b895d11dbeeac4a9693bf))
* **dashboard:** add Max-Age and Secure to the cookie ([267d8ac](https://github.com/This-Is-NPC/atanor/commit/267d8ac200c0a063afe351478df178314794ea95))
* **drain:** omit progress until alambique begins ([3257f76](https://github.com/This-Is-NPC/atanor/commit/3257f76d367e70c1aacc4ed825a3ea6be7a4a546))
* **http:** use a fixed retry-after for held_elsewhere ([2ebdebf](https://github.com/This-Is-NPC/atanor/commit/2ebdebfd4a6a05cb12368f1dbe0caf852dc76eb0))

## 0.1.0 (2026-11-05)

First release.

### Features

* **cells:** a named stateful cell per tenant, with its own SQLite, a single owner, replication to S3, wake on demand and sleep when idle; migrations per namespace; partitioned cells for namespaces that one writer cannot serve; limits on statements, awake cells and local files, and a memory budget that hibernates the least used cells
* **workers:** native Elixir workers and WebAssembly components (`wasi:http`, run by Wasmtime through an own NIF with CPU, memory and wall-clock limits), with manifests and grant-checked bindings: cells, secrets, outbound HTTP and calls to other workers
* **ingress:** HTTP routing by host and path, WebSockets attached to cells, ephemeral channels for cursors and presence, raw TCP listeners with routing keys, TLS and STARTTLS with reloadable certificates, Ranch protocol listeners (gen_smtp, for example), and OIDC access tokens required per route
* **jobs:** jobs and alarms per cell, with retries, cron, unique keys, a dead-letter set and idempotent effects; native and WASM workers alike
* **feed:** a change feed per namespace that native workers read by page or subscribe to without waking cells, at least once, with grouped objects, table selection and compressed objects
* **sweeps:** bulk operations that enqueue one job in many cells, throttled, guarded and resumable, with an undo that reports and rewinds the cells
* **cluster:** routing of every request to the owner of its cell, a phi accrual failure detector, takeover with leases and epoch fencing, graceful stop, a platform hint that a node is gone, automatic placement of hot cells, bounded reads from replicas, and failover in milliseconds for a killed process and seconds for a lost machine
* **deploy:** deployments by package hash, the `atanor` command (deploy, activate, rollback) through an admin API with scoped tokens and an audit log, and migration rehearsals on copies of sampled cells
* **observe:** telemetry per worker, deployment and cell, an admin API for workers, deployments, routes, live cells and peers, crash reports that name the job or operation that died, and an optional read-only dashboard
* **dev:** `mix atanor.dev` for a local node over an in-memory store, the `atanor_testkit` helpers (nodes, clusters with fault injection) and runnable examples
* **lab:** a cluster of three VMs over one SeaweedFS and a Docker Compose cluster, both with fault injection, and benchmarks for the main costs

### Miscellaneous

* **license:** MIT
