# KinoPub Enchancements

## Styles

```css
:root :not(i, .material-symbols-outlined, .material-icons) {
  text-transform: initial!important;
}

:root #aside,
:root .navside .navbar,
:root .navside .hide-scroll,
:root .navside .scroll {
  display: content!important;
  all: unset!important;
}
:root .navside {
  position: fixed!important;
  top: 0!important;
  left: 0!important;
  right: 0!important;
  bottom: auto!important;
  height: 3.5rem!important;
  width: 100%!important;
  display: flex!important;
  flex-direction: row!important;
  gap: 2rem;
  align-items: center;
  padding: 0 1.5rem;
}
/* Logo */
:root .navbar-brand {
  display: flex;
  padding: 0!important;
  flex-shrink: 1!important;
  flex-grow: 0!important;
  width: min-content!important;
}
:root .navbar-brand svg {
  position: static!important;
}
:root .navbar-brand .hidden-folded {
  display: none!important;
}

/* Nav Bar */
:root .nav {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  flex-shrink: 0!important;
  flex-grow: 1!important;
  margin: 0!important;
  padding: 0!important;
  grid-column-gap: 1rem;
}

:root .nav li:nth-child(1),
:root .nav li:nth-child(2),
:root .nav li:nth-child(3),
:root .nav li:nth-child(4),
:root .nav li:nth-child(5),
:root .nav li:nth-child(6),
:root .nav li:nth-child(7),
:root .nav li:nth-child(8),
:root .nav li:nth-child(9),
:root .nav li:nth-child(10),
:root .nav li:nth-child(14),
:root .nav li:nth-child(15),
:root .nav li:nth-child(16),
:root .nav li:nth-child(17),
:root .nav li:nth-child(18),
:root .nav li:nth-child(23),
:root .nav li:nth-child(24),
:root .nav li:nth-child(25),
:root .nav li.nav-header {
  display: none!important;
}

#aside .nav li a {
  display: flex!important;
  flex-direction: row!important;
  align-items: center;
  grid-gap: 0.25rem;
  flex-wrap: nowrap;
  margin: 0!important;
  padding: 0!important;
  line-height: 1.5!important;
}
#aside .nav li a .nav-icon {
 margin: 0!important;
}
#aside .nav li a .nav-text {
 white-space: nowrap;
}

/* Content */

#content {
  margin-left: 0!important;
  margin-top: 3.5rem;
}


/* Bookmarks */
div[id^="favorites-item-"],
.card-block {
  position: relative;
}
div[id^="favorites-item-"] a,
.card-block a {
  z-index: 2;
  position: relative;
}
div[id^="favorites-item-"] .item-title a,
.card-block h6 a {
  z-index: 0;
  position: initial;
}
div[id^="favorites-item-"] .item-title a::before,
.card-block h6 a::before {
  content: "";
  position: absolute;
  top:0;
  left:0;
  right:0;
  bottom:0;
  z-index: 1;
}

.episode-number a {
  display: inline-block;
  padding:0.5rem 0.7rem;
  z-index:100;
  text-decoration: underline!important;
}
.episode-number a:hover {
  text-decoration: none!important;
}

h3 select {
  max-width: 8rem;
  background-color: transparent;
  float: right;
  padding: 0.3rem 0.5rem!important;
}
h3 select + select {
  margin-right: 1rem!important;
}
```

## Scripts

```js
window.addEventListener('DOMContentLoaded',()=>{
  const code = document
    .querySelector("#media-playlist + .mediaplayer script")
    .innerHTML
    ?.match(/var playlist = (\[\{.*\}\]);/m)
    ?.[1]

  const playlist = JSON.parse(code)

  const header = document.querySelector('h3')
  const copyToClipboardSelect = createCopyToClipboardSelect();
  const openInIinaSelect = createOpenInIinaSelect();

  playlist.forEach(media => {
    copyToClipboardSelect.add(createOption(media))
    openInIinaSelect.add(createOption(media))
  })

  header.appendChild(copyToClipboardSelect)
  header.appendChild(openInIinaSelect)

  console.table(playlist)
})

function createCopyToClipboardSelect() {
  const select = document.createElement("select");
  select.className = "btn btn-outline b-success"
  select.value = ""

  select.onchange = (e) => {
    if (!select.value) {
      return
    }

    navigator.clipboard.writeText(select.value)
    console.log('Copied to clipboard: ', select.value)
  }

  const option = document.createElement("option");
  option.text = "copy .m3u"
  option.value = ""
  select.add(option)

  return select
}

function createOpenInIinaSelect() {
  const select = document.createElement("select");
  select.className = "btn btn-outline b-success"
  select.value = ""

  select.onchange = (e) => {
    if (!select.value) {
      return
    }

    const baseURL = `iina://open?`;
    const params = [`url=${encodeURIComponent(select.value).replace(/'/g, '%27')}`];
    params.push("enqueue=0");
    params.push("new_window=0");

    var link = document.createElement("a");
    link.href = `${baseURL}${params.join("&")}`;
    document.body.appendChild(link);
    link.click();

    console.log('Copied to clipboard: ', select.value, link.href)
  }

  const option = document.createElement("option");
  option.text = "open .m3u"
  option.value = ""
  select.add(option)

  return select
}

function createOption(media) {
  const node = document.createElement("option");
  node.value = media.file;
  const title = media?.title || 'Link to m3u'
  node.text = title;
  node.label = title
  return node;
}

```