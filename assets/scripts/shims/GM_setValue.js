const GM_setValue = function(key, value) {
    // 油猴允许存对象，LocalStorage 只能存字符串，所以要 JSON 序列化
    localStorage.setItem("GM_STORAGE_PREFIX_" + key, JSON.stringify(value));
};