// ============================================================
// app.js —— 前端逻辑
//
// 功能：
//   1. 渲染左侧分类栏 + 右侧菜品列表（数据来自 menu.js）
//   2. 点击分类 → 切换右侧菜品（不向 AI 提问）
//   3. 点击菜品「+」按钮 → 加入底部「已点菜」栏
//   4. 底部已点菜栏：显示已点菜品、数量、合计金额，可清空
//   5. 底部输入栏 → 发送消息给 AI（上方对话框展示回复）
// ============================================================

// 后端地址
// 自动跟随当前访问地址：电脑用 127.0.0.1，手机用局域网 IP，都能正确调用接口
const API_BASE = window.location.origin;

// 对话历史（多轮上下文）
let chatHistory = [];

// 已点菜列表：{ name, price, desc, count }
let cart = [];

// 已点菜栏是否展开
let cartExpanded = false;

// DOM 元素
const chatArea = document.getElementById("chatArea");
const inputBox = document.getElementById("inputBox");
const sendBtn = document.getElementById("sendBtn");
const categorySide = document.getElementById("categorySide");
const dishSide = document.getElementById("dishSide");

// ------------------------------------------------------------
// 1. 渲染左侧分类栏
// ------------------------------------------------------------
function renderCategories() {
    categorySide.innerHTML = "";
    categories.forEach((cat, idx) => {
        const div = document.createElement("div");
        div.className = "cat-item" + (idx === 0 ? " active" : "");
        div.textContent = cat;
        div.dataset.cat = cat;
        div.addEventListener("click", () => scrollToCategory(cat, div));
        categorySide.appendChild(div);
    });

    // 渲染右侧连续长列表
    renderAllDishes();
}

// ------------------------------------------------------------
// 2. 渲染右侧：所有分类连成一个连续长列表
// ------------------------------------------------------------
function renderAllDishes() {
    dishSide.innerHTML = "";

    categories.forEach(cat => {
        const dishes = menuData[cat] || [];

        // 分类标题（锚点）
        const header = document.createElement("div");
        header.className = "dish-category-header";
        header.id = "cat-" + cat;
        header.textContent = cat;
        dishSide.appendChild(header);

        if (dishes.length === 0) {
            const tip = document.createElement("div");
            tip.className = "empty-tip";
            tip.textContent = "该分类暂无菜品";
            dishSide.appendChild(tip);
            return;
        }

        dishes.forEach(d => {
            const item = document.createElement("div");
            item.className = "dish-item";

            // 菜品图片：优先用 d.img 字段，否则按「菜名.png」自动找图
            const imgWrap = document.createElement("div");
            imgWrap.className = "dish-img";

            const imgEl = document.createElement("img");
            // 图片路径：web/images/dishes/菜名.png
            const imgPath = d.img || `images/dishes/${d.name}.png`;
            imgEl.src = imgPath;
            imgEl.alt = d.name;
            imgEl.className = "dish-img-real";
            // 图片加载失败时，显示 emoji 占位
            imgEl.addEventListener("error", () => {
                imgEl.style.display = "none";
                imgWrap.textContent = "🍲";
            });
            imgWrap.appendChild(imgEl);

            const info = document.createElement("div");
            info.className = "dish-info";
            const name = document.createElement("div");
            name.className = "dish-name";
            name.textContent = d.name;
            info.appendChild(name);

            const price = document.createElement("div");
            price.className = "dish-price";
            price.innerHTML = `¥${d.price} <span class="unit">/份</span>`;

            const addBtn = document.createElement("button");
            addBtn.className = "add-btn";
            addBtn.textContent = "+";
            addBtn.addEventListener("click", (e) => {
                e.stopPropagation();
                addToCart(d);
            });

            item.appendChild(imgWrap);
            item.appendChild(info);
            item.appendChild(price);
            item.appendChild(addBtn);
            dishSide.appendChild(item);
        });
    });
}

// ------------------------------------------------------------
// 3. 点击左侧分类 → 平滑滚动到对应分类标题
// ------------------------------------------------------------
function scrollToCategory(cat, el) {
    const target = document.getElementById("cat-" + cat);
    if (target) {
        // 滚动到分类标题（减去一点顶部偏移，让标题不被遮住）
        dishSide.scrollTo({
            top: target.offsetTop - 8,
            behavior: "smooth",
        });
    }
    // 高亮
    document.querySelectorAll(".cat-item").forEach(n => n.classList.remove("active"));
    el.classList.add("active");
}

// ------------------------------------------------------------
// 3b. 滚动联动：根据右侧滚动位置，自动高亮左侧分类
// ------------------------------------------------------------
function updateActiveCategoryOnScroll() {
    const headers = dishSide.querySelectorAll(".dish-category-header");
    if (headers.length === 0) return;

    const scrollTop = dishSide.scrollTop;
    const threshold = dishSide.offsetTop + 10;  // 顶部判定线

    let currentCat = null;
    headers.forEach(h => {
        // 如果分类标题已经滚到顶部判定线之上，则它是最新的分类
        if (h.offsetTop <= scrollTop + threshold) {
            currentCat = h.textContent;
        }
    });

    if (currentCat) {
        document.querySelectorAll(".cat-item").forEach(n => {
            if (n.dataset.cat === currentCat) {
                n.classList.add("active");
            } else {
                n.classList.remove("active");
            }
        });
    }
}

// ------------------------------------------------------------
// 4. 已点菜（购物车）逻辑
// ------------------------------------------------------------
function addToCart(dish) {
    // 查找是否已点过
    const existing = cart.find(c => c.name === dish.name);
    if (existing) {
        existing.count += 1;
    } else {
        cart.push({ name: dish.name, price: parseFloat(dish.price), desc: dish.desc || "份", count: 1 });
    }
    renderCart();
}

function removeFromCart(name) {
    const idx = cart.findIndex(c => c.name === name);
    if (idx !== -1) {
        cart[idx].count -= 1;
        if (cart[idx].count <= 0) {
            cart.splice(idx, 1);
        }
    }
    renderCart();
}

function clearCart() {
    cart = [];
    renderCart();
}

// 折叠/展开已点菜列表
function toggleCart() {
    cartExpanded = !cartExpanded;
    const cartList = document.getElementById("cartList");
    const toggleText = document.getElementById("cartToggleText");
    const toggleArrow = document.getElementById("cartToggleArrow");

    if (cartExpanded) {
        cartList.style.display = "block";
        toggleText.textContent = "收起";
        toggleArrow.textContent = "▴";
    } else {
        cartList.style.display = "none";
        toggleText.textContent = cart.length > 0 ? `查看已点菜(${cart.reduce((s, c) => s + c.count, 0)})` : "查看已点菜";
        toggleArrow.textContent = "▾";
    }
}

function renderCart() {
    const cartList = document.getElementById("cartList");
    const cartTotal = document.getElementById("cartTotal");
    const cartBadge = document.getElementById("cartBadge");
    const toggleText = document.getElementById("cartToggleText");

    // 清空列表
    cartList.innerHTML = "";

    if (cart.length === 0) {
        cartList.innerHTML = '<div class="cart-empty">尚未点菜</div>';
        cartTotal.textContent = "¥0";
        cartBadge.style.display = "none";
        toggleText.textContent = "查看已点菜";
        // 没菜时自动收起
        if (cartExpanded) {
            cartExpanded = false;
            cartList.style.display = "none";
            document.getElementById("cartToggleArrow").textContent = "▾";
        }
    } else {
        cart.forEach(c => {
            const row = document.createElement("div");
            row.className = "cart-row";

            const name = document.createElement("span");
            name.className = "cart-name";
            name.textContent = c.name;

            const controls = document.createElement("span");
            controls.className = "cart-controls";

            const minus = document.createElement("button");
            minus.className = "cart-btn";
            minus.textContent = "−";
            minus.addEventListener("click", () => removeFromCart(c.name));

            const count = document.createElement("span");
            count.className = "cart-count";
            count.textContent = c.count;

            const plus = document.createElement("button");
            plus.className = "cart-btn";
            plus.textContent = "+";
            plus.addEventListener("click", () => addToCart({ name: c.name, price: c.price, desc: c.desc }));

            const price = document.createElement("span");
            price.className = "cart-price";
            price.textContent = `¥${(c.price * c.count).toFixed(0)}`;

            controls.appendChild(minus);
            controls.appendChild(count);
            controls.appendChild(plus);
            controls.appendChild(price);

            row.appendChild(name);
            row.appendChild(controls);
            cartList.appendChild(row);
        });

        // 清空按钮（放在列表底部）
        const clearRow = document.createElement("div");
        clearRow.className = "cart-clear-row";
        const clearBtn = document.createElement("button");
        clearBtn.className = "cart-clear";
        clearBtn.textContent = "清空已点菜";
        clearBtn.addEventListener("click", clearCart);
        clearRow.appendChild(clearBtn);
        cartList.appendChild(clearRow);

        const total = cart.reduce((sum, c) => sum + c.price * c.count, 0);
        cartTotal.textContent = `¥${total.toFixed(0)}`;

        const count = cart.reduce((sum, c) => sum + c.count, 0);
        cartBadge.textContent = count;
        cartBadge.style.display = "flex";

        // 折叠状态下更新按钮文字
        if (!cartExpanded) {
            toggleText.textContent = `查看已点菜(${count})`;
        }
    }
}

// ------------------------------------------------------------
// 清理 Markdown 符号（前端兜底）
// 去掉 **加粗**、`代码`、# 标题、列表前缀 - 等符号
// ------------------------------------------------------------
function cleanMarkdown(text) {
    if (!text) return text;
    return text
        .replace(/\*\*/g, "")                 // 去掉 **加粗**
        .replace(/`/g, "")                    // 去掉反引号
        .replace(/^#{1,6}\s+/gm, "")          // 去掉行首的 # 标题
        .replace(/^\s*[-*]\s+/gm, "")         // 去掉行首的 - 或 * 列表符号
        .replace(/^\s*>\s?/gm, "");           // 去掉行首的 > 引用符号
}

// ------------------------------------------------------------
// 5. 对话区：追加消息
// ------------------------------------------------------------
function appendMessage(role, text, sources = [], dishes = [], mealInfo = null) {
    const msgDiv = document.createElement("div");
    msgDiv.className = `msg ${role}`;

    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.textContent = text;

    if (sources && sources.length > 0) {
        const srcDiv = document.createElement("div");
        srcDiv.className = "sources";
        sources.forEach(s => {
            const tag = document.createElement("span");
            tag.className = "src-tag";
            tag.textContent = `📎 ${s.category} · ${s.source}`;
            srcDiv.appendChild(tag);
        });
        bubble.appendChild(srcDiv);
    }

    // 配菜结果：展示清单（不带加购按钮）+ 合计 + 人均
    if (role === "assistant" && mealInfo && mealInfo.is_meal && dishes && dishes.length > 0) {
        const mealBox = document.createElement("div");
        mealBox.className = "meal-result";

        // 菜品清单
        dishes.forEach(d => {
            const row = document.createElement("div");
            row.className = "meal-row";
            const nm = document.createElement("span");
            nm.className = "meal-row-name";
            nm.textContent = d.name.replace(/^【.*?】/, "");  // 去掉分类前缀
            const pr = document.createElement("span");
            pr.className = "meal-row-price";
            pr.textContent = "¥" + (d.price || "0");
            row.appendChild(nm);
            row.appendChild(pr);
            mealBox.appendChild(row);
        });

        // 合计（不显示人均）
        const summary = document.createElement("div");
        summary.className = "meal-summary";
        summary.textContent = "合计 ¥" + (mealInfo.total || 0);
        mealBox.appendChild(summary);

        // 一键全部加入购物车按钮
        const addAllBtn = document.createElement("button");
        addAllBtn.className = "meal-add-all";
        addAllBtn.textContent = "🛒 一键加入购物车";
        addAllBtn.addEventListener("click", () => {
            let count = 0;
            dishes.forEach(d => {
                const cleanName = d.name.replace(/^【.*?】/, "");
                addToCart({ name: cleanName, price: d.price || "0", desc: "" });
                count++;
            });
            addAllBtn.classList.add("added");
            addAllBtn.textContent = `已加入 ${count} 道菜 ✓`;
            setTimeout(() => {
                addAllBtn.classList.remove("added");
                addAllBtn.textContent = "🛒 一键加入购物车";
            }, 1500);
        });
        mealBox.appendChild(addAllBtn);

        bubble.appendChild(mealBox);
    }
    // 普通推荐：带「加入购物车」按钮
    else if (role === "assistant" && dishes && dishes.length > 0) {
        const dishBar = document.createElement("div");
        dishBar.className = "dish-actions";
        dishes.forEach(d => {
            const btn = document.createElement("button");
            btn.className = "dish-action-btn";
            const cleanName = d.name.replace(/^【.*?】/, "");
            btn.innerHTML = `+ ${cleanName}` + (d.price ? ` <span class="dish-action-price">¥${d.price}</span>` : "");
            btn.addEventListener("click", () => {
                addToCart({ name: cleanName, price: d.price || "0", desc: "" });
                btn.classList.add("added");
                btn.textContent = "已加入 ✓";
                setTimeout(() => {
                    btn.classList.remove("added");
                    btn.innerHTML = `+ ${cleanName}` + (d.price ? ` <span class="dish-action-price">¥${d.price}</span>` : "");
                }, 1200);
            });
            dishBar.appendChild(btn);
        });
        bubble.appendChild(dishBar);
    }

    msgDiv.appendChild(bubble);
    chatArea.appendChild(msgDiv);
    chatArea.scrollTop = chatArea.scrollHeight;
    return msgDiv;
}

function showTyping() {
    const msgDiv = document.createElement("div");
    msgDiv.className = "msg assistant";
    msgDiv.id = "typing";
    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.innerHTML = '<span class="typing-dot"></span><span class="typing-dot"></span><span class="typing-dot"></span>';
    msgDiv.appendChild(bubble);
    chatArea.appendChild(msgDiv);
    chatArea.scrollTop = chatArea.scrollHeight;
}

function removeTyping() {
    const typing = document.getElementById("typing");
    if (typing) typing.remove();
}

// ------------------------------------------------------------
// 6. 发送消息（核心）
// ------------------------------------------------------------
async function sendMessage(text) {
    if (!text.trim()) return;

    appendMessage("user", text);
    inputBox.value = "";
    chatHistory.push({ role: "user", content: text });

    showTyping();

    try {
        const resp = await fetch(`${API_BASE}/api/chat`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                message: text,
                history: chatHistory,
            }),
        });
        const data = await resp.json();

        removeTyping();
        const reply = cleanMarkdown(data.reply);
        // 配菜结果带上 meal 信息（total/people/is_meal）
        const mealInfo = data.is_meal ? {
            is_meal: true,
            total: data.total,
            people: data.people,
        } : null;
        appendMessage("assistant", reply, data.sources || [], data.dishes || [], mealInfo);
        chatHistory.push({ role: "assistant", content: reply });

    } catch (err) {
        removeTyping();
        appendMessage("assistant", "⚠️ 无法连接后端服务，请确认已运行 python app.py\n错误：" + err.message);
    }
}

// ------------------------------------------------------------
// 7. 事件绑定
// ------------------------------------------------------------
sendBtn.addEventListener("click", () => sendMessage(inputBox.value));
inputBox.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
        sendMessage(inputBox.value);
    }
});

document.getElementById("cartToggleBtn").addEventListener("click", toggleCart);

// 配菜表单：打开/关闭
const mealModal = document.getElementById("mealModal");
function openMealModal() {
    mealModal.style.display = "flex";
}
function closeMealModal() {
    mealModal.style.display = "none";
}
document.getElementById("mealPlanBtn").addEventListener("click", openMealModal);
document.getElementById("mealCancel").addEventListener("click", closeMealModal);
document.getElementById("mealMask").addEventListener("click", closeMealModal);

// 配菜表单：提交
document.getElementById("mealConfirm").addEventListener("click", () => {
    const people = document.getElementById("mealPeople").value.trim();
    const budget = document.getElementById("mealBudget").value.trim();
    const taste = document.getElementById("mealTaste").value.trim();
    const avoid = document.getElementById("mealAvoid").value.trim();

    // 组装成自然语言需求
    let req = "帮我配一桌菜";
    if (people) req += `，${people}个人`;
    if (budget) req += `，预算${budget}元左右`;
    if (taste) req += `，口味偏好${taste}`;
    if (avoid) req += `，忌口：${avoid}`;

    closeMealModal();
    // 清空表单
    document.getElementById("mealPeople").value = "";
    document.getElementById("mealBudget").value = "";
    document.getElementById("mealTaste").value = "";
    document.getElementById("mealAvoid").value = "";

    sendMessage(req);
});

// 顶部标签页切换
function switchTab(tab) {
    // 切换标签高亮
    document.querySelectorAll(".tab-item").forEach(n => n.classList.remove("active"));
    document.getElementById(tab === "ai" ? "tabAi" : "tabMenu").classList.add("active");

    // 切换内容面板
    document.querySelectorAll(".tab-panel").forEach(n => n.classList.remove("active"));
    document.getElementById(tab === "ai" ? "panelAi" : "panelMenu").classList.add("active");
}

document.getElementById("tabAi").addEventListener("click", () => switchTab("ai"));
document.getElementById("tabMenu").addEventListener("click", () => switchTab("menu"));

// 初始化
renderCategories();
renderCart();

// 右侧菜品列表滚动时，联动高亮左侧分类
dishSide.addEventListener("scroll", updateActiveCategoryOnScroll);
