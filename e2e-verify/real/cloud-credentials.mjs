// 验收账号凭据（gitignored 报告目录内引用，值存于 deploy/acceptance.env / /tmp/acc-daemon/acc.txt）。
import { readFileSync } from "node:fs";
const [email, password] = readFileSync("/tmp/acc-daemon/acc.txt", "utf8").trim().split(" ");
export const loginEmail = email;
export const loginPassword = password;
