#!/usr/bin/env bash

HERDR_ALIAS_COLORS=(
  amber aqua azure beige black blue bronze brown
  coral cream crimson cyan gold gray green indigo
  ivory jade khaki lilac lime magenta maroon navy
  ochre olive orange pink purple red silver teal
)

HERDR_ALIAS_ANIMALS=(
  aardvark
  abyssinian
  affenpinscher
  akbash
  akita
  alligator
  alpaca
  ant
  anteater
  antelope
  arapaima
  armadillo
  aurochs
  avocet
  axolotl
  baboon
  badger
  baiji
  balinese
  barb
  bat
  bear
  beetle
  birman
  bison
  blobfish
  boar
  bobcat
  boggle
  bombay
  bongo
  bonobo
  booby
  buffalo
  bulldog
  bullfrog
  bumblebee
  burmese
  camel
  caracal
  carp
  cassowary
  cat
  caterpillar
  catfish
  centipede
  chameleon
  chamois
  cheetah
  chicken
  chihuahua
  chimaera
  chimpanzee
  chinchilla
  chinook
  cicada
  cichlid
  clownfish
  coati
  cobra
  cockatoo
  cockroach
  codfish
  coelacanth
  collie
  coral
  cougar
  cow
  coyote
  crab
  crane
  crocodile
  crow
  dachshund
  dalmatian
  damselfly
  deer
  dhole
  dingo
  discus
  dodo
  dog
  dogo
  dolphin
  donkey
  dormouse
  duck
  dugong
  eagle
  earwig
  echidna
  eel
  elephant
  elk
  emu
  ermine
  falcon
  ferret
  finch
  fish
  flamingo
  flounder
  fluke
  fly
  fossa
  fox
  frog
  gar
  gecko
  gibbon
  giraffe
  goat
  goose
  gopher
  gorilla
  grasshopper
  greyhound
  grouse
  guinea
  hamster
  hare
  hedgehog
  heron
  herring
  hippopotamus
  horse
  human
  hyena
  ibex
  ibis
  iguana
  impala
  insect
  jackal
  jaguar
  jellyfish
  jerboa
  kakapo
  kangaroo
  kiwi
  koala
  krill
  kudu
  lemming
  lemur
  leopard
  liger
  lion
  lizard
  llama
  loach
  lobster
  locust
  lungfish
  lynx
  macaw
  mole
  molly
  mongoose
  mongrel
  monkey
  monkfish
  moose
  moth
  mouse
  mule
  narwhal
  newt
  numbat
  ocelot
  octopus
  okapi
  olm
  opossum
  ostrich
  otter
  oyster
  panda
  pangolin
  panther
  parrot
  peacock
  pelican
  penguin
  pheasant
  pig
  pigeon
  pika
  platypus
  pointer
  polar
  porcupine
  porpoise
  possum
  prawn
  puffin
  pug
  quail
  quetzal
  quokka
  quoll
  rabbit
  raccoon
  rat
  rattlesnake
  raven
  reindeer
  rhinoceros
  robin
  salamander
  salmon
  samoyed
  sawfish
  scorpion
  seal
  serval
  shark
  sheep
  shrimp
  skunk
  sloth
  snail
  snake
  sparrow
  squid
  squirrel
  starfish
  stoat
  sturgeon
  swan
  termite
  terrier
  tetra
  tiger
  toad
  tortoise
  toucan
  tuna
  turkey
  vulture
  wallaby
  walrus
  wasp
  weasel
  whale
  whippet
  wolf
  wombat
  woodpecker
  worm
  zebra
  zebu
)

# A microsecond floor for monotonic reconciliation generations and metadata.
herdr_now_seq() {
  if command -v python3 >/dev/null 2>&1; then
    local value
    value="$(python3 -c 'import time; print(int(time.time()*1000000))' 2>/dev/null)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  printf '%s000000' "$(date +%s)"
}

herdr_alias_is_valid() {
  [[ $# -eq 1 ]] || return 2
  local alias="$1"

  [[ ${#alias} -le 32 && "$alias" =~ ^[a-z]+-[a-z]+$ ]]
}

herdr_alias_in_pool() {
  [[ $# -eq 1 ]] || return 2
  local alias="$1"
  local color animal word
  local color_found=0 animal_found=0

  herdr_alias_is_valid "$alias" || return 1
  color="${alias%%-*}"
  animal="${alias#*-}"

  for word in "${HERDR_ALIAS_COLORS[@]}"; do
    if [[ "$word" == "$color" ]]; then
      color_found=1
      break
    fi
  done
  for word in "${HERDR_ALIAS_ANIMALS[@]}"; do
    if [[ "$word" == "$animal" ]]; then
      animal_found=1
      break
    fi
  done

  [[ $color_found -eq 1 && $animal_found -eq 1 ]]
}

_herdr_alias_validate_words() {
  local kind="$1"
  shift
  local words=("$@")
  local i j word

  if [[ ${#words[@]} -eq 0 ]]; then
    printf 'herdr aliases: %s list is empty\n' "$kind" >&2
    return 1
  fi

  for ((i = 0; i < ${#words[@]}; i++)); do
    word="${words[$i]}"
    if [[ ! "$word" =~ ^[a-z]+$ ]]; then
      printf 'herdr aliases: invalid %s word: %s\n' "$kind" "$word" >&2
      return 1
    fi
    for ((j = i + 1; j < ${#words[@]}; j++)); do
      if [[ "$word" == "${words[$j]}" ]]; then
        printf 'herdr aliases: duplicate %s word: %s\n' "$kind" "$word" >&2
        return 1
      fi
    done
  done
}

herdr_alias_validate_pool() {
  local color animal alias
  local color_count=${#HERDR_ALIAS_COLORS[@]}
  local animal_count=${#HERDR_ALIAS_ANIMALS[@]}

  _herdr_alias_validate_words color "${HERDR_ALIAS_COLORS[@]}" || return 1
  _herdr_alias_validate_words animal "${HERDR_ALIAS_ANIMALS[@]}" || return 1
  if ((color_count * animal_count < 1024)); then
    printf 'herdr aliases: pool has fewer than 1024 candidates\n' >&2
    return 1
  fi

  # Unique words on both sides of the separator make every pair unique.
  for color in "${HERDR_ALIAS_COLORS[@]}"; do
    for animal in "${HERDR_ALIAS_ANIMALS[@]}"; do
      alias="$color-$animal"
      if ! herdr_alias_is_valid "$alias"; then
        printf 'herdr aliases: invalid candidate: %s\n' "$alias" >&2
        return 1
      fi
    done
  done
}

herdr_alias_candidates() {
  [[ $# -eq 1 ]] || return 2
  herdr_alias_validate_pool || return 1

  local seed checksum_line checksum
  local color_count=${#HERDR_ALIAS_COLORS[@]}
  local animal_count=${#HERDR_ALIAS_ANIMALS[@]}
  local pool_size=$((color_count * animal_count))
  local offset step index color_index animal_index

  if [[ -n "${HERDR_ALIAS_TEST_SEED+x}" ]]; then
    seed="$HERDR_ALIAS_TEST_SEED"
  else
    seed="$1"
  fi
  checksum_line="$(printf '%s' "$seed" | cksum)" || return 1
  checksum="${checksum_line%%[[:space:]]*}"
  [[ "$checksum" =~ ^[0-9]+$ ]] || return 1
  offset=$((checksum % pool_size))

  for ((step = 0; step < pool_size; step++)); do
    index=$(((offset + step) % pool_size))
    color_index=$((index / animal_count))
    animal_index=$((index % animal_count))
    printf '%s-%s\n' \
      "${HERDR_ALIAS_COLORS[$color_index]}" \
      "${HERDR_ALIAS_ANIMALS[$animal_index]}"
  done
}
