#!/usr/bin/env node
import {readFileSync,statSync} from 'node:fs';
import {resolve,dirname} from 'node:path';

const usage='Usage: node bin/relcore.mjs <plan.json> [--md]\nExit: 0 contracts pass; 1 contract violations; 2 invalid input or I/O.';
const args=process.argv.slice(2);
if(args.length===1&&['-h','--help'].includes(args[0])){console.log(usage);process.exit(0);}
const markdown=args.includes('--md');
const planArgs=args.filter(arg=>arg!=='--md');
if(planArgs.length!==1){console.error(usage);process.exit(2);}

try{
  const planPath=resolve(planArgs[0]);
  if(statSync(planPath).size>64*1024*1024)throw new Error('plan exceeds 64 MiB');
  const document=JSON.parse(readFileSync(planPath,'utf8'));
  const base=dirname(planPath);
  for(const source of Object.values(document.sources||{})){
    if(source&&source.path&&!source.data){
      source.data=readFileSync(resolve(base,source.path),'utf8');
      delete source.path;
    }
  }
  const core=await import('../dist/relcore.js');
  const documentText=JSON.stringify(document);
  if(document.baseline&&document.candidate){
    const raw=core.compare(documentText);
    console.log(raw);
    const parsed=JSON.parse(raw);
    process.exitCode=parsed.error?2:(parsed.ok?0:1);
  }else if(markdown){
    const raw=core.run(documentText);
    const parsed=JSON.parse(raw);
    console.log(parsed.error?raw:core.run_markdown(documentText));
    process.exitCode=parsed.error?2:(parsed.ok?0:1);
  }else{
    const raw=core.run(documentText);
    console.log(raw);
    const parsed=JSON.parse(raw);
    process.exitCode=parsed.error?2:(parsed.ok?0:1);
  }
}catch(error){
  console.error(JSON.stringify({ok:false,error:{code:'IO_OR_RUNTIME',message:error.message}}));
  process.exitCode=2;
}
