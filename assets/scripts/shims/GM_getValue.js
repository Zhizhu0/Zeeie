const GM_getValue = function(key, defaultValue) {
    var value = localStorage.getItem("GM_STORAGE_PREFIX_" + key);
    if (value === null) return defaultValue;
    try {
        return JSON.parse(value);
    } catch(e) {
        return value; 
    }
};