const GM_addStyle = function(css) {
    var style = document.createElement('style');
    style.textContent = css;

    var target = document.head || document.documentElement;

    if (target) {
        target.appendChild(style);
    } else {
        // 创建一个观察者，一旦 <head> 或 <html> 出现就立即插入
        var observer = new MutationObserver(function(mutations, obs) {
            var target = document.head || document.documentElement;
            if (target) {
                target.appendChild(style);
                obs.disconnect(); // 任务完成，停止观察
            }
        });
        
        // 开始观察 document 的子节点变化
        observer.observe(document, { childList: true, subtree: true });
    }
    
    // 返回 style 元素以便后续操作（符合 GM_addStyle 标准）
    return style;
};