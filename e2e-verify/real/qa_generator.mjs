// v0.7/P4 固定无敏感问答池与弱 oracle。
// 题目只用于本地进程内请求；报告、checkpoint 和日志只引用题目 ID 与类型，
// 不保存 question 字段，避免把测试输入误当成长期证据。

export const GENERATOR_VERSION = "v07-qa-pool-1";
export const PROMPT_ORACLE_VERSION = "v07-weak-oracle-1";

// 题目池固定为中英文各 16 条，覆盖数学、代码、翻译、解释和列表五类短问题。
// 所有内容都是公开知识或合成例子，不包含账号、路径、凭据、个人或机密数据。
export const QUESTION_POOL = Object.freeze([
  { id: "zh-math-01", language: "zh", type: "math", variants: ["请计算 17 加 25，并用一句话说明结果。", "请算出 17 + 25，并简短说明结果。"] },
  { id: "zh-math-02", language: "zh", type: "math", variants: ["一个长度为 8、宽度为 5 的矩形面积是多少？", "矩形长 8、宽 5，它的面积是多少？"] },
  { id: "zh-math-03", language: "zh", type: "math", variants: ["把 3/4 写成小数，并给出结果。", "请将四分之三转换成小数。"] },
  { id: "zh-math-04", language: "zh", type: "math", variants: ["数列 2、4、6、8 的下一个数是什么？", "序列 2、4、6、8 继续时，下一个数字是多少？"] },
  { id: "zh-code-01", language: "zh", type: "code", variants: ["请用 Python 写一个函数，返回字符串中元音字母的数量，并给出一个简短示例。", "请用 Python 实现统计字符串元音数量的函数，再给一个小示例。"] },
  { id: "zh-code-02", language: "zh", type: "code", variants: ["请用 JavaScript 写一个数组去重函数，保持原顺序。", "请写一个保持原顺序的 JavaScript 数组去重函数。"] },
  { id: "zh-code-03", language: "zh", type: "code", variants: ["请用 Go 展示一个读取 JSON 对象的最小示例。", "请给出 Go 读取 JSON 对象的最小代码示例。"] },
  { id: "zh-code-04", language: "zh", type: "code", variants: ["请用 SQL 写出按部门统计员工数量的查询示例。", "请写一条 SQL，按部门统计员工数量。"] },
  { id: "zh-translation-01", language: "zh", type: "translation", variants: ["请把“今天的天气很晴朗”翻译成英文。", "请将“今天的天气很晴朗”译为英文。"] },
  { id: "zh-translation-02", language: "zh", type: "translation", variants: ["请把“Keep the list sorted”翻译成中文。", "请将“Keep the list sorted”翻译成简洁中文。"] },
  { id: "zh-translation-03", language: "zh", type: "translation", variants: ["请说明单词 “concise” 的中文含义。", "请用中文解释 “concise” 这个英文词。"] },
  { id: "zh-explanation-01", language: "zh", type: "explanation", variants: ["用两句话解释什么是二叉树。", "请用两句简单的话说明二叉树是什么。"] },
  { id: "zh-explanation-02", language: "zh", type: "explanation", variants: ["用简单语言解释 HTTP 状态码 404。", "请用通俗语言说明 HTTP 404 代表什么。"] },
  { id: "zh-list-01", language: "zh", type: "list", variants: ["列出三个适合晨间计划的简单步骤。", "请列出晨间计划的三个简单步骤。"] },
  { id: "zh-list-02", language: "zh", type: "list", variants: ["列出三种减少重复代码的方法。", "请列出三种降低代码重复的方法。"] },
  { id: "zh-explanation-03", language: "zh", type: "explanation", variants: ["用一个日常例子解释缓存为什么能提升速度。", "请用日常例子说明缓存为何可以让读取更快。"] },
  { id: "en-math-01", language: "en", type: "math", variants: ["Calculate 19 plus 23 and state the result in one short sentence.", "What is 19 + 23? Give the result in one short sentence."] },
  { id: "en-math-02", language: "en", type: "math", variants: ["What is the area of a rectangle that is 7 units wide and 6 units high?", "Find the area of a 7 by 6 rectangle."] },
  { id: "en-math-03", language: "en", type: "math", variants: ["Convert three quarters to a decimal and give the result.", "Write three quarters as a decimal."] },
  { id: "en-math-04", language: "en", type: "math", variants: ["The sequence 5, 10, 15, 20 continues with which number?", "What number comes next after 5, 10, 15, 20?"] },
  { id: "en-code-01", language: "en", type: "code", variants: ["Write a Python function that counts vowels in a string and show a tiny example.", "Show Python code for counting vowels in a string, including a small example."] },
  { id: "en-code-02", language: "en", type: "code", variants: ["Write a JavaScript function that removes duplicate array items while preserving order.", "Show JavaScript code that deduplicates an array without changing its order."] },
  { id: "en-code-03", language: "en", type: "code", variants: ["Show a minimal Go example that reads a JSON object.", "Give a minimal Go code example for reading a JSON object."] },
  { id: "en-code-04", language: "en", type: "code", variants: ["Write a SQL example that counts employees grouped by department.", "Show SQL that counts employees for each department."] },
  { id: "en-translation-01", language: "en", type: "translation", variants: ["Translate “The sky is clear today” into Chinese.", "How would you translate “The sky is clear today” into Chinese?"] },
  { id: "en-translation-02", language: "en", type: "translation", variants: ["Translate “请保持列表有序” into English.", "Translate the Chinese phrase “请保持列表有序” into English."] },
  { id: "en-translation-03", language: "en", type: "translation", variants: ["Explain the Chinese meaning of the word “concise”.", "What is a concise Chinese meaning for the word “concise”? "] },
  { id: "en-explanation-01", language: "en", type: "explanation", variants: ["Explain what a binary tree is in two short sentences.", "In two short sentences, explain a binary tree."] },
  { id: "en-explanation-02", language: "en", type: "explanation", variants: ["Explain HTTP status code 404 in plain language.", "What does HTTP status code 404 mean? Explain simply."] },
  { id: "en-list-01", language: "en", type: "list", variants: ["List three simple steps for a calm morning plan.", "Give three simple steps for planning a calm morning."] },
  { id: "en-list-02", language: "en", type: "list", variants: ["List three ways to reduce duplicated code.", "Name three ways to reduce code duplication."] },
  { id: "en-explanation-03", language: "en", type: "explanation", variants: ["Use an everyday example to explain why caching can improve speed.", "Explain with an everyday example how caching can make reads faster."] },
]);

const SENSITIVE_TERMS = Object.freeze([
  "password", "api key", "secret", "credential", "private key", "token",
  "密码", "密钥", "凭据", "私钥", "身份证", "银行卡", "机密", "个人信息",
]);

function normalizeSeed(seed) {
  const text = String(seed ?? "").trim() || "20260829";
  let hash = 2_166_136_261;
  for (const char of text) {
    hash ^= char.codePointAt(0);
    hash = Math.imul(hash, 16_777_619);
  }
  return hash >>> 0;
}

function random32(seed) {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function shuffled(values, next) {
  const copy = [...values];
  for (let index = copy.length - 1; index > 0; index -= 1) {
    const swap = Math.floor(next() * (index + 1));
    [copy[index], copy[swap]] = [copy[swap], copy[index]];
  }
  return copy;
}

function promptFor(item, next) {
  const variant = item.variants[Math.floor(next() * item.variants.length)];
  const prefixes = item.language === "zh"
    ? ["", "请简洁回答：", "请先给出结论："]
    : ["", "Answer briefly: ", "Start with the result: "];
  const prefix = prefixes[Math.floor(next() * prefixes.length)];
  return `${prefix}${variant}`.trim();
}

function oracleFor(type) {
  switch (type) {
    case "code":
      return { kind: "non_empty", requires_code_fence: true };
    case "math":
      return { kind: "non_empty", requires_number: true };
    case "list":
      return { kind: "non_empty", requires_list_shape: true };
    default:
      return { kind: "non_empty", min_length: 2 };
  }
}

// generateQuestions 以 seed 固定随机顺序，同时保证选中的中英文数量尽量各半。
// count 超过题池时直接报错，避免通过重复题目虚增 full gate 覆盖量。
export function generateQuestions({ seed = "20260829", count = 12 } = {}) {
  if (!Number.isInteger(count) || count < 1 || count > QUESTION_POOL.length) {
    throw new RangeError(`题目数量必须在 1-${QUESTION_POOL.length} 之间`);
  }
  const next = random32(normalizeSeed(seed));
  const zh = shuffled(QUESTION_POOL.filter((item) => item.language === "zh"), next);
  const en = shuffled(QUESTION_POOL.filter((item) => item.language === "en"), next);
  const zhCount = Math.ceil(count / 2);
  const selected = [];
  for (let index = 0; index < zhCount; index += 1) selected.push(zh[index]);
  for (let index = 0; index < count - zhCount; index += 1) selected.push(en[index]);
  const ordered = shuffled(selected, next);
  return ordered.map((item) => ({
    id: item.id,
    language: item.language,
    type: item.type,
    question: promptFor(item, next),
    minExpect: oracleFor(item.type),
  }));
}

export function hasSensitiveQuestionContent(value) {
  const normalized = String(value ?? "").toLowerCase();
  return SENSITIVE_TERMS.some((term) => normalized.includes(term.toLowerCase()));
}

// checkResponseOracle 只检查弱结构，不比较模型的具体答案，避免把模型自然表达误判为失败。
export function checkResponseOracle(question, response) {
  const text = String(response ?? "").trim();
  if (text.length < 2) return { ok: false, reason: "empty_response" };
  if (hasSensitiveQuestionContent(question)) return { ok: false, reason: "sensitive_question" };
  if (question?.minExpect?.requires_code_fence && !text.includes("```")) {
    return { ok: false, reason: "missing_code_fence" };
  }
  if (question?.minExpect?.requires_number && !(/[0-9]|零|一|二|三|四|五|六|七|八|九|十/.test(text))) {
    return { ok: false, reason: "missing_numeric_result" };
  }
  if (question?.minExpect?.requires_list_shape && !(/(^|\n)\s*(?:[-*•]|\d+[.)])/.test(text) || text.includes("\n"))) {
    return { ok: false, reason: "missing_list_shape" };
  }
  return { ok: true, reason: null };
}

export function questionPoolSummary() {
  return {
    count: QUESTION_POOL.length,
    languages: {
      zh: QUESTION_POOL.filter((item) => item.language === "zh").length,
      en: QUESTION_POOL.filter((item) => item.language === "en").length,
    },
    types: [...new Set(QUESTION_POOL.map((item) => item.type))].sort(),
    generator_version: GENERATOR_VERSION,
    oracle_version: PROMPT_ORACLE_VERSION,
  };
}
