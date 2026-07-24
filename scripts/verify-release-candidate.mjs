import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("../", import.meta.url).pathname;
const manifest = JSON.parse(readFileSync(join(root,"release/candidate-v1.json"),"utf8"));
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const files = (directory) => readdirSync(directory).flatMap((entry) => {
  const path=join(directory,entry);
  return statSync(path).isDirectory()?files(path):[path];
});
const sourceLines=files(join(root,"contracts/src")).map((path)=>relative(root,path)).sort().map((path)=>`${sha256(readFileSync(join(root,path)))}  ${path}\n`).join("");
const checks = {
  contractsSourceTreeSha256:sha256(sourceLines),
  constantsFileSha256:sha256(readFileSync(join(root,"contracts/src/libraries/BabyNoxaConstants.sol"))),
  packageLockSha256:sha256(readFileSync(join(root,"package-lock.json"))),
};
for(const [name,actual] of Object.entries(checks)){
  const expected=manifest.source[name];
  if(actual!==expected)throw new Error(`${name} mismatch: expected ${expected}, received ${actual}`);
}
for(const [contract,expected] of Object.entries(manifest.deployedBytecodeKeccak256)){
  const bytecode=execFileSync("forge",["inspect",contract,"deployedBytecode"],{cwd:join(root,"contracts"),encoding:"utf8"}).trim();
  const actual=execFileSync("cast",["keccak",bytecode],{encoding:"utf8"}).trim();
  if(actual!==expected)throw new Error(`${contract} bytecode mismatch: expected ${expected}, received ${actual}`);
}
if(manifest.status!=="not-approved-for-production")throw new Error("Pre-audit candidate must remain not approved for production");
process.stdout.write(`Verified ${manifest.candidate}: source, lockfile, constants, and ${Object.keys(manifest.deployedBytecodeKeccak256).length} bytecode hashes match.\n`);
