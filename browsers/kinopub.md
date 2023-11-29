# KinoPub Enchancements

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