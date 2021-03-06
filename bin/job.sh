#!/bin/bash
#
# set -x


# This is the tinderbox script itself.
# The main function is WorkOnTask().
# The remaining code just parses the output.
# That's all.


# strip away quotes
#
function stripQuotesAndMore() {
  sed -e 's,['\''‘’"`],,g' |\
  sed -e 's/\xE2\x80\x98|\xE2\x80\x99//g' # UTF-2018+2019 (left+right single quotation mark)
}


# strip away escape sequences, eg. colours et al.
#
function stripEscapeSequences() {
  perl -MTerm::ANSIColor=colorstrip -nle '
    $_ = colorstrip($_);
    s,\x1B\x5B\x4B,,g;
    s,\x1B...,,g;
    s,\x00,\n,g;
    s,\r,\n,g;
    print;
  '
}


# send out a non-MIME-compliant email
#
# $1 (mandatory) is the SMTP subject,
# $2 (optionally) contains either the message or a file (maybe containing MIME encoded parts)
#
function Mail() {
  subject=$(echo "$1" | stripQuotesAndMore | cut -c1-200 | tr '\n' ' ')

  # the Debian mailx automatically adds a MIME SMTP header line
  # But uuencode is not MIME-compliant, therefore newer Thunderbird versions shows
  # any attachment as inline text only :-(
  #
  # a workaround is to insert an empty SMTP header line before that SMTP header line to invalidate its special meaning
  # but do this only if there're uuencoded attachments
  #
  [[ -f $2 ]] && grep -q "^begin 644 " $2 && dummy='-a dummy_header_line' || dummy=""

  (
    if [[ -f $2 ]]; then
      ls -l $2
      echo
      cat $2
    else
      echo "${2:-empty_mail_body}"
    fi
  ) | timeout 120 mail $dummy -s "$subject    @ $name" -- $mailto &>> /var/tmp/tb/mail.log

  if [[ $? -ne 0 ]]; then
    echo "$(date) mail failed, \$rc=$rc, \$subject=$subject  \$2=$2" | tee -a /var/tmp/tb/mail.log
  fi
}


# clean up and exit
#
# $1: return code
# $2: email Subject
# $3: file to be attached
#
function Finish()  {
  local rc=$1
  subject=$(echo "$2" | stripQuotesAndMore | tr '\n' ' ' | cut -c1-200)

  /usr/bin/pfl &>/dev/null

  if [[ $rc -eq 0 ]]; then
    Mail "Finish ok: $subject" $3
  else
    Mail "Finish NOT ok, rc=$rc: $subject" ${3:-$logfile}
  fi

  rm -f /var/tmp/tb/STOP
  exit $rc
}


# helper of getNextTask()
#
function setTaskAndBacklog()  {
  if [[ -s $backlog1st ]]; then
    backlog=$backlog1st

  elif [[ -s /var/tmp/tb/backlog.upd && $(($RANDOM % 3)) -eq 0 ]]; then
    backlog=/var/tmp/tb/backlog.upd

  elif [[ -s /var/tmp/tb/backlog ]]; then
    backlog=/var/tmp/tb/backlog

  elif [[ -s /var/tmp/tb/backlog.upd ]]; then
    backlog=/var/tmp/tb/backlog.upd

  else
    Finish 0 "all backlogs are EMPTY, $(qlist --installed | wc -l) packages installed"
  fi

  # copy the last line to $task and splice that line from the backlog
  task=$(tail -n 1 $backlog)
  sed -i -e '$d' $backlog
}


# verify/parse $task accordingly to the needs of the tinderbox
#
function getNextTask() {
  while [[ : ]]; do
    setTaskAndBacklog

    if [[ -z "$task" || $task =~ ^# ]]; then
      continue  # empty line or comment

    elif [[ $task =~ ^INFO ]]; then
      Mail "$task"
      continue

    elif [[ $task =~ ^STOP ]]; then
      echo "#stopping" > $taskfile
      Finish 0 "$task"

    elif [[ $task =~ ^@ || $task =~ ^% ]]; then
      break  # @set or %command

    elif [[ $task =~ ^= ]]; then
      # pinned version, but check validity
      portageq best_visible / $task &>/dev/null && break

    else
      if [[ ! "$backlog" = $backlog1st ]]; then
        echo "$task" | grep -q -f /mnt/tb/data/IGNORE_PACKAGES && continue
      fi

      # skip if $task is masked, keyworded or just an invalid atom
      #
      best_visible=$(portageq best_visible / $task 2>/dev/null) || continue

      # skip if $task is installed and would be downgraded
      #
      installed=$(portageq best_version / $task)
      if [[ -n "$installed" ]]; then
        qatom --compare $installed $best_visible | grep -q -e ' == ' -e ' > ' && continue
      fi

      # $task is valid
      #
      break
    fi
  done

  echo "$task" | tee -a $taskfile.history $logfile > $taskfile
}


# helper of CollectIssueFiles
#
function collectPortageDir()  {
  (cd / && tar -cjpf $issuedir/files/etc.portage.tbz2 --dereference etc/portage)
}


# b.g.o. has a limit of 1 MB
#
function CompressIssueFiles()  {
  for f in $( ls $issuedir/task.log $issuedir/files/* 2>/dev/null )
  do
    if [[ $(wc -c < $f) -gt 1000000 ]]; then
      bzip2 $f
    fi
  done
}


# helper of GotAnIssue()
# gather together what's needed for the email and b.g.o.
#
function CollectIssueFiles() {
  local ehist=/var/tmp/tb/emerge-history.txt
  local cmd="qlop --nocolor --verbose --merge --unmerge"

  cat << EOF > $ehist
# This file contains the emerge history got with:
# $cmd
#
EOF
  ($cmd) &>> $ehist

  apout=$(grep -m 1 -A 2 'Include in your bugreport the contents of'                 $logfile_stripped | grep "\.out"          | cut -f5 -d' ' -s)
  cmlog=$(grep -m 1 -A 2 'Configuring incomplete, errors occurred'                   $logfile_stripped | grep "CMake.*\.log"   | cut -f2 -d'"' -s)
  cmerr=$(grep -m 1      'CMake Error: Parse error in cache file'                    $logfile_stripped | sed  "s/txt./txt/"    | cut -f8 -d' ' -s)
  oracl=$(grep -m 1 -A 1 '# An error report file with more information is saved as:' $logfile_stripped | grep "\.log"          | cut -f2 -d' ' -s)
  envir=$(grep -m 1      'The ebuild environment file is located at'                 $logfile_stripped                         | cut -f2 -d"'" -s)
  salso=$(grep -m 1 -A 2 ' See also'                                                 $logfile_stripped | grep "\.log"          | awk '{ print $1 }' )
  sandb=$(grep -m 1 -A 1 'ACCESS VIOLATION SUMMARY' $logfile_stripped                                  | grep "sandbox.*\.log" | cut -f2 -d'"' -s)
  roslg=$(grep -m 1 -A 1 'Tests failed. When you file a bug, please attach the following file: ' $logfile_stripped | grep "/LastTest\.log" | awk ' { print $2 } ')

  for f in $ehist $pkglog $sandb $apout $cmlog $cmerr $oracl $envir $salso $roslg
  do
    if [[ -f $f ]]; then
      cp $f $issuedir/files
    fi
  done

  CompressIssueFiles

  if [[ -d "$workdir" ]]; then
    # catch all log file(s)
    (
      f=/var/tmp/tb/files
      cd "$workdir/.." &&\
      find ./ -name "*.log" -o -name "testlog.*" -o -wholename '*/elf/*.out' > $f &&\
      [[ -s $f ]] &&\
      tar -cjpf $issuedir/files/logs.tbz2 \
        --dereference --warning='no-file-removed' --warning='no-file-ignored' \
        --files-from $f 2>/dev/null
      rm -f $f
    )

    # additional cmake files
    #
    cp ${workdir}/*/CMakeCache.txt $issuedir/files/ 2>/dev/null

    # provide the whole temp dir if possible
    #
    (
      cd "$workdir/../.." &&\
      [[ -d ./temp ]]     &&\
      timeout -s 15 180 tar -cjpf $issuedir/files/temp.tbz2 \
          --dereference --warning='no-file-removed' --warning='no-file-ignored'  \
          --exclude='*/kerneldir/*' --exclude='*/var-tests/*' --exclude='*/go-build[0-9]*/*' \
          --exclude='*/testdirsymlink/*' --exclude='*/go-cache/??/*' \
          ./temp
    )

    # ICE of GCC ?
    #
    if [[ -f $workdir/gcc-build-logs.tar.bz2 ]]; then
      cp $workdir/gcc-build-logs.tar.bz2 $issuedir/files
    fi
  fi

  collectPortageDir
}


# strip away the version (get $PN from $P)
#
function pn2p() {
  qatom --quiet "$1" 2>/dev/null | grep -v '(null)' | cut -f1-2 -d' ' -s | tr ' ' '/'
}


# helper of GotAnIssue()
# get failed package and logfile names
#
function getPkgVarsFromIssuelog()  {
  pkg="$(cd /var/tmp/portage; ls -1td */* 2>/dev/null | head -n 1)" # head due to 32/64 multilib variants
  if [[ -z "$pkg" ]]; then # eg. in postinst phase
    pkg=$(grep -m 1 -F ' * Package: ' $logfile_stripped | awk ' { print $3 } ')
    if [[ -z "$pkg" ]]; then
      pkg=$(grep -m 1 '>>> Failed to emerge .*/.*' $logfile_stripped | cut -f5 -d' ' -s | cut -f1 -d',' -s)
      if [[ -z "$pkg" ]]; then
        pkg=$(grep -F ' * Fetch failed' $logfile_stripped | grep -o "'.*'" | sed "s,',,g")
      fi
    fi
  fi

  pkgname=$(pn2p "$pkg")

  # double check that the values are ok
  #
  repo=$(portageq metadata / ebuild $pkg repository)
  repo_path=$(portageq get_repo_path / $repo)
  if [[ ! -d $repo_path/$pkgname ]]; then
    Mail "INFO: $FUNCNAME failed to get repo path for:  >$pkg<  >$pkgname<  >$task<" $logfile_stripped
    return 1
  fi

  pkglog=$(grep -o -m 1 "/var/log/portage/$(echo $pkgname | tr '/' ':').*\.log" $logfile_stripped)
  if [[ ! -f $pkglog ]]; then
    Mail "INFO: $FUNCNAME failed to get package log file:  >$pkg<  >$pkgname<  >$task<  >$pkglog<" $logfile_stripped
    return 1
  fi
}


# set assignee and cc for the b.g.o. record
#
function SetAssigneeAndCc() {
  local assignee
  local cc

  local m=$(equery meta -m $pkgname 2>/dev/null | grep '@' | xargs)

  if [[ -z "$m" ]]; then
    assignee="maintainer-needed@gentoo.org"
    cc=""

  elif [[ "$blocker_bug_no" = "561854" ]]; then
    assignee="libressl@gentoo.org"
    cc="$m"

  elif [[ ! $repo = "gentoo" ]]; then
    if [[ $repo = "science" ]]; then
      assignee="sci@gentoo.org"
    else
      assignee="$repo@gentoo.org"
    fi
    cc="$m"

  elif [[ $name =~ "musl" ]]; then
    assignee="musl@gentoo.org"
    cc="$m"

  else
    assignee=$(echo "$m" | cut -f1 -d' ')
    cc=$(echo "$m" | cut -f2- -d' ' -s)
  fi

  echo "$assignee" > $issuedir/assignee
  # the file is pre-filled eg. at a file collision detection
  [[ -s $issuedir/cc ]] && cc="$cc $(cat $issuedir/cc)"
  [[ -n "$cc" ]] && echo "$cc" | xargs -n 1 | sort -u | grep -v "^$assignee$" | xargs > $issuedir/cc
}


# add this eg. to #comment0 of an b.g.o. record
#
function AddWhoamiToComment0() {
  cat << EOF >> $issuedir/comment0

  -------------------------------------------------------------------

  This is an $keyword amd64 chroot image at a tinderbox (==build bot)
  name: $name

  -------------------------------------------------------------------

EOF
}


# attach given files onto the email
# (should be called after the lines of text)
#
function AttachFilesToBody()  {
  for f in $*
  do
    if [[ -f $f ]]; then
      local s=$( wc -c < $f )
      if [[ $s -gt 0 && $s -lt 1048576 ]]; then
        echo >> $issuedir/body
        uuencode $f ${f##*/} >> $issuedir/body
        echo >> $issuedir/body
      fi
    fi
  done
}


# query b.g.o. about same/similar bug reports
#
function AddVersionAssigneeAndCC() {
  cat << EOF >> $issuedir/body

--
versions: $(eshowkw --overlays --arch amd64 $pkgname | grep -v -e '^  *|' -e '^-' -e '^Keywords' | awk '{ if ($3 == "+") { print $1 } else if ($3 == "o") { print "**"$1 } else { print $3$1 } }' | xargs)
assignee: $(cat $issuedir/assignee)
cc:       $(cat $issuedir/cc 2>/dev/null)
--

EOF
}


# helper of GotAnIssue()
#
function CreateIssueDir() {
  issuedir=/var/tmp/tb/issues/$(date +%Y%m%d-%H%M%S)-$(echo $pkg | tr '/' '_')
  mkdir -p $issuedir/files
  chmod 777 $issuedir # allow to edit title etc. manually
}


# helper of ClassifyIssue()
#
function foundCollisionIssue() {
  grep -m 1 -A 20 ' * Detected file collision(s):' $logfile_stripped | grep -B 15 ' * Package .* NOT' > $issuedir/issue

  # get package (name+version) of the colliding package
  local s=$(grep -m 1 -A 2 'Press Ctrl-C to Stop' $logfile_stripped | grep '::' | tr ':' ' ' | cut -f3 -d' ' -s)
  echo "file collision with $s" > $issuedir/title

  # inform both parties of the collision
  equery meta -m $s 2>/dev/null | grep '@' | xargs > $issuedir/cc
}


# helper of ClassifyIssue()
#
function foundSandboxIssue() {
  grep -q "=$pkg " /etc/portage/package.env/nosandbox 2>/dev/null
  if [[ $? -ne 0 ]]; then
    printf "%-50s %s\n" "<=$pkg" "nosandbox" >> /etc/portage/package.env/nosandbox
    try_again=1
  fi

  echo "sandbox issue" > $issuedir/title
  if [[ -f $sandb ]]; then
    head -n 10 $sandb > $issuedir/issue 2>&1
  else
    echo "Bummer, sandbox file does not exist: $sandb" > $issuedir/issue
  fi
}


# helper of ClassifyIssue()
#
function foundCflagsIssue() {
  grep -q "=$pkg " /etc/portage/package.env/cflags_default 2>/dev/null
  if [[ $? -ne 0 ]]; then
    printf "%-50s %s\n" "<=$pkg" "cflags_default" >> /etc/portage/package.env/cflags_default
    try_again=1
  fi

  echo "$1" > $issuedir/title
}


# helper of foundGenericIssue()
#
function handleTestPhase() {
  grep -q "=$pkg " /etc/portage/package.env/test-fail-continue 2>/dev/null
  if [[ $? -ne 0 ]]; then
    printf "%-50s %s\n" "<=$pkg" "test-fail-continue" >> /etc/portage/package.env/test-fail-continue
    try_again=1
  fi

  # tar returns an error if it can't find at least one directory
  # therefore feed only existing dirs to it
  #
  pushd "$workdir" 1>/dev/null
  dirs="$(ls -d ./tests ./regress ./t ./Testing ./testsuite.dir 2>/dev/null)"
  if [[ -n "$dirs" ]]; then
    # the tar here is know to spew things like the obe below so ignore errors
    # tar: ./automake-1.13.4/t/instspc.dir/a: Cannot stat: No such file or directory
    tar -cjpf $issuedir/files/tests.tbz2 \
      --exclude="*/dev/*" --exclude="*/proc/*" --exclude="*/sys/*" --exclude="*/run/*" \
      --exclude='*.o' --exclude="*/symlinktest/*" \
      --dereference --sparse --one-file-system --warning='no-file-ignored' \
      $dirs 2>/dev/null
  fi
  popd 1>/dev/null

  echo "TESTFAILURE" >> $issuedir/keywords
}


# helper of ClassifyIssue()
#
function foundGenericIssue() {
    pushd /var/tmp/tb 1>/dev/null

    # run over manually collected pattern in the order they do appear in the appropriate pattern file
    # as an attempt to get the real issue
    #
    (
      [[ -n "$phase" ]] && cat /mnt/tb/data/CATCH_ISSUES.$phase
      cat /mnt/tb/data/CATCH_ISSUES
    ) | split --lines=1 --suffix-length=2

    # the amount of echos must match the argument of -B 2 in the grep in the for-loop
    echo                  >  ./stripped_pkglog
    echo                  >> ./stripped_pkglog
    cat $pkglog_stripped  >> ./stripped_pkglog

    for x in ./x??
    do
      grep -a -m 1 -B 2 -A 3 -f $x ./stripped_pkglog > ./issue
      if [[ $? -eq 0 ]]; then
        mv ./issue $issuedir
        sed -n '3p' < $issuedir/issue | stripQuotesAndMore > $issuedir/title # 3p == 3rd line == matches -A 3
        break
      fi
    done

    rm -f ./x?? ./stripped_pkglog ./issue

    popd 1>/dev/null

    # strip away hex addresses, line and time numbers and other stuff
    #
    sed -i  -e 's/0x[0-9a-f]*/<snip>/g'         \
            -e 's/: line [0-9]*:/:line <snip>:/g' \
            -e 's/[0-9]* Segmentation fault/<snip> Segmentation fault/g' \
            -e 's/Makefile:[0-9]*/Makefile:<snip>/g' \
            -e 's,:[[:digit:]]*): ,:<snip>:,g'  \
            -e 's,([[:digit:]]* of [[:digit:]]*),(<snip> of <snip)>,g'  \
            -e 's,  *, ,g'                      \
            -e 's,[0-9]*[\.][0-9]* sec,,g'      \
            -e 's,[0-9]*[\.][0-9]* s,,g'        \
            -e 's,([0-9]*[\.][0-9]*s),,g'       \
            -e 's/ \.\.\.*\./ /g'               \
            -e 's/___*/_/g'                     \
            -e 's/; did you mean .* \?$//g'     \
            -e 's/(@INC contains:.*)/.../g'     \
            -e "s,ld: /.*/cc......\.o: ,ld: ,g" \
            -e 's,target /.*/,target <snip>/,g' \
            $issuedir/title
}


# helper of GotAnIssue()
# get the issue and a descriptive title
#
function ClassifyIssue() {
  touch $issuedir/{issue,title}

  # for phase "install" grep might return > 1 matches ("doins failed" and "newins failed")
  phase=$(
    grep -m 1 " \* ERROR:.* failed (.* phase):" $pkglog_stripped |\
    sed -e 's/.* failed \(.* phase\)/\1/g' | cut -f2 -d'(' | cut -f1 -d' '
  )

  if [[ "$phase" = "test" ]]; then
    handleTestPhase
  fi

  if [[ -n "$(grep -m 1 ' * Detected file collision(s):' $pkglog_stripped)" ]]; then
    foundCollisionIssue

  elif [[ -n $sandb ]]; then # no test at "-f" b/c it might not be allowed to be written
    foundSandboxIssue

  elif [[ -n "$(grep -m 1 -B 4 -A 1 ': multiple definition of ' $pkglog_stripped | tee $issuedir/issue)" ]]; then
    foundCflagsIssue 'fails to build with -fno-common or gcc-10'

  elif [[ -n "$(grep -m 1 -B 4 -A 1 'sed:.*expression.*unknown option' $pkglog_stripped | tee $issuedir/issue)" ]]; then
    foundCflagsIssue 'ebuild uses colon (:) as a sed delimiter'

  elif [[ -n "$(grep -m 1 -B 3 -A 0 ': error:.*.-Werror=format-security.' $pkglog_stripped | tee $issuedir/issue)" ]]; then
    foundCflagsIssue "$(tail -n 1 $issuedir/issue)"

  else
    grep -m 1 -A 2 " \* ERROR:.* failed (.* phase):" $pkglog_stripped | tee $issuedir/issue |\
    head -n 2 | tail -n 1 > $issuedir/title
    foundGenericIssue
  fi

  # if the issue file is too big, then delete in each loop the 1st line as long as needed
  #
  while [[ $(wc -c < $issuedir/issue) -gt 1024 && $(wc -l < $issuedir/issue) -gt 1 ]]; do
    sed -i -e "1d" $issuedir/issue
  done
}


# test title against known blocker
# the BLOCKER file contains paragraphs like:
#
#   # comment
#   <bug id>
#   <pattern string ready for grep -E>
#
# if <pattern> is defined more than once then the first makes it
#
function SearchForBlocker() {
  if [[ ! -s $issuedir/title ]]; then
    return 0
  fi

  local number=""
  while read line
  do
    if [[ $line =~ ^[0-9].*$ ]]; then
      number=$line
      continue
    fi

    grep -q -E "$line" $issuedir/title
    if [[ $? -eq 0 ]]; then
      blocker_bug_no=$number
      break
    fi
  done < <(grep -v -e '^#' -e '^$' /mnt/tb/data/BLOCKER)
}


# enrich email body by b.g.o. findings and links
#
function SearchForAnAlreadyFiledBug() {
  if [[ ! -s $issuedir/title ]]; then
    return
  fi

  bsi=$issuedir/bugz_search_items     # use the title as a set of space separated search patterns

  # get away line numbers, certain special terms et al
  sed -e 's,&<[[:alnum:]].*>,,g'  \
      -e 's,/\.\.\./, ,'          \
      -e 's,:[[:alnum:]]*:[[:alnum:]]*: , ,g' \
      -e 's,.* : ,,'              \
      -e 's,[<>&\*\?], ,g'        \
      -e 's,[\(\)], ,g'           \
      -e 's,  *, ,g'              \
      $issuedir/title > $bsi

  # for the file collision case: remove the package version from the installed package
  #
  grep -q "file collision" $bsi && sed -i -e 's/\-[0-9\-r\.]*$//g' $bsi

  # truncation accordingly to the b.g.o. title length limit, the used number here is heuristic
  # b/c we don't take the package name length here into account
  if [[ $(wc -c < $bsi) -gt 90 ]]; then
    truncate -s 90 $bsi
  fi

  # search first for the same version, second for category/package name
  # take the highest bug id and put the summary of the next (newest) 10 bugs into the email body
  #
  for i in $pkg $pkgname
  do
    similar_bug_no=$(timeout 300 bugz -q --columns 400 search --show-status -- $i "$(cat $bsi)" 2>>$issuedir/bugz.err | grep -e " CONFIRMED " -e " IN_PROGRESS " | sort -u -n -r | head -n 10 | tee -a $issuedir/body | head -n 1 | cut -f1 -d' ')
    if [[ -n "$similar_bug_no" ]]; then
      echo "CONFIRMED " >> $issuedir/bgo_result
      break
    fi

    for s in FIXED WORKSFORME DUPLICATE
    do
      similar_bug_no=$(timeout 300 bugz -q --columns 400 search --show-status --resolution $s --status RESOLVED -- $i "$(cat $bsi)" 2>>$issuedir/bugz.err | sort -u -n -r | head -n 10 | tee -a $issuedir/body | head -n 1 | cut -f1 -d' ')
      if [[ -n "$similar_bug_no" ]]; then
        echo "$s " >> $issuedir/bgo_result  # trailing space is intentionally
        break 2
      fi
    done
  done
}


# compile a command line ready for copy+paste to file a bug
# and add the top 20 b.g.o. search results too
#
function AddBgoCommandLine() {
  local block=""
  if [[ -n "$blocker_bug_no" ]]; then
    block="-b $blocker_bug_no"
  fi

  if [[ -n "$similar_bug_no" ]]; then
    cat << EOF >> $issuedir/body
  https://bugs.gentoo.org/show_bug.cgi?id=$similar_bug_no

  bgo.sh -d ~/img?/$name/$issuedir $block -c 'this seems to be either still an issue or a similarity to the one reported in bug $similar_bug_no'
EOF

  else
    # SearchForAnAlreadyFiledBug() was unsuccessful, so look here for the latest open/closed reports
    # as a hint, whether the bgo.sh command line should be fired up or not
    #
    cat << EOF >> $issuedir/body

  bgo.sh -d ~/img?/$name/$issuedir $block

EOF

    echo "" >> $issuedir/body

    h='https://bugs.gentoo.org/buglist.cgi?query_format=advanced&short_desc_type=allwordssubstr'
    g='stabilize|Bump| keyword| bump'

    echo "  OPEN:     $h&resolution=---&short_desc=$pkgname" >> $issuedir/body
    timeout 300 bugz -q --columns 400 search --show-status     $pkgname 2>>$issuedir/bugz.err | grep -v -i -E "$g" | sort -u -n -r | head -n 20 >> $issuedir/body

    echo "" >> $issuedir/body

    echo "  RESOLVED: $h&bug_status=RESOLVED&short_desc=$pkgname" >> $issuedir/body
    timeout 300 bugz -q --columns 400 search --status RESOLVED $pkgname 2>>$issuedir/bugz.err | grep -v -i -E "$g" | sort -u -n -r | head -n 20 >> $issuedir/body
  fi

  # append a newline to make copy+paste from Thunderbird message window more convenient
  #
  echo >> $issuedir/body
}


# b.g.o. limits "Summary"
#
function TrimTitle()  {
  truncate -s "<${1:-130}" $issuedir/title
}


# helper of GotAnIssue()
# creates an email containing convenient links and a command line ready for copy+paste
#
function CompileIssueMail() {
  emerge -p --info $pkgname &> $issuedir/emerge-info.txt

  # shrink loong path names and :lineno:columno: pattern
  #
  sed -i -e 's,/[^ ]*\(/[^/:]*:\),/...\1,g' -e 's,:[[:digit:]]*:[[:digit:]]*: ,: ,' $issuedir/title

  cat $issuedir/issue | stripEscapeSequences > $issuedir/comment0

  # cut a too long #comment0
  #
  while [[ $(wc -c < $issuedir/comment0) -gt 4000 ]]
  do
    sed -i '1d' $issuedir/comment0
  done

  # copy it to the email body before enriching it
  #
  cp $issuedir/comment0 $issuedir/body
  AddWhoamiToComment0

  if [[ -n "$block" ]]; then
    cat <<EOF >> $issuedir/comment0
  Please see the tracker bug for details.

EOF
  fi

  grep -q -e "Can't locate .* in @INC" ${bak}
  if [[ $? -eq 0 ]]; then
    cat <<EOF >> $issuedir/comment0
  Please see https://wiki.gentoo.org/wiki/Project:Perl/Dot-In-INC-Removal#Counter_Balance

EOF
  fi

  AddVersionAssigneeAndCC

  (
    echo "gcc-config -l:"
    gcc-config -l

    clang --version
    llvm-config --prefix --version
    eselect python list
    eselect ruby list
    eselect rust list
    java-config --list-available-vms --nocolor
    eselect java-vm list
    ghc --version

    echo
    echo "  timestamp(s) of HEAD at this tinderbox image:"
    for i in /var/db/repos/*/timestamp.git
    do
      echo -e "${i%/*}\t$(date -u -d @$(cat $i))"
    done

    echo
    echo "emerge -qpvO $pkgname"
    head -n 1 $issuedir/emerge-qpvO
  ) >> $issuedir/comment0 2>/dev/null

  if [[ -s $issuedir/title ]]; then
    TrimTitle 200
    SearchForAnAlreadyFiledBug
  fi

  AddBgoCommandLine
  AttachFilesToBody $issuedir/bugz.* $issuedir/emerge-info.txt $issuedir/task.log* $issuedir/files/*

  # finalize title
  sed -i -e "s,^,${pkg} :," $issuedir/title
  if [[ $phase = "test" ]]; then
    sed -i -e "s,^,[TEST] ," $issuedir/title
  fi
  if [[ $repo != "gentoo" ]]; then
    sed -i -e "s,^,[$repo overlay] ," $issuedir/title
  fi
  TrimTitle

  # grant write permissions to all artifacts
  #
  chmod    777  $issuedir/{,files}
  chmod -R a+rw $issuedir/
}


# helper of GotAnIssue() and CheckQA
#
function SendoutIssueMail()  {
  if [[ -s $issuedir/title ]]; then
    # do not inform about a known issue twice
    #
    grep -F -q -f $issuedir/title /mnt/tb/data/ALREADY_CATCHED 2>/dev/null && return
    cat $issuedir/title >> /mnt/tb/data/ALREADY_CATCHED
  fi
  Mail "$(cat $issuedir/bgo_result 2>/dev/null)$(cat $issuedir/title)" $issuedir/body
}


# helper of GotAnIssue()
# add successfully emerged packages to world (otherwise we'd need "--deep" unconditionally)
# https://bugs.gentoo.org/show_bug.cgi?id=563482
#
function PutDepsIntoWorldFile() {
  emerge --depclean --pretend --verbose=n 2>/dev/null |\
  grep "^All selected packages: "                     |\
  cut -f2- -d':' -s                                   |\
  xargs --no-run-if-empty emerge -O --noreplace
}


# helper of GotAnIssue()
# for ABI_X86="32 64" we have two ./work directories in /var/tmp/portage/<category>/<name>
#
function setWorkDir() {
  workdir=$(fgrep -m 1 " * Working directory: '" $logfile_stripped | cut -f2 -d"'" -s)
  if [[ ! -d "$workdir" ]]; then
    workdir=$(fgrep -m 1 ">>> Source unpacked in " $logfile_stripped | cut -f5 -d" " -s)
    if [[ ! -d "$workdir" ]]; then
      workdir=/var/tmp/portage/$pkg/work/${pkg##*/}
      if [[ ! -d "$workdir" ]]; then
        workdir=""
      fi
    fi
  fi
}


function add2backlog()  {
  # no duplicates
  #
  if [[ ! "$(tail -n 1 $backlog1st)" = "${@}" ]]; then
    echo "${@}" >> $backlog1st
  fi
}


# collect files and compile an email
#
function GotAnIssue()  {
  grep -q -F '^>>> Installing ' $logfile_stripped
  if [[ $? -eq 0 ]]; then
    PutDepsIntoWorldFile &>/dev/null
  fi

  fatal=$(grep -m 1 -f /mnt/tb/data/FATAL_ISSUES $logfile_stripped)
  if [[ -n "$fatal" ]]; then
    Finish 1 "FATAL: $fatal"
  fi

  grep -q -e "Exiting on signal" -e " \* The ebuild phase '.*' has been killed by signal" $logfile_stripped
  if [[ $? -eq 0 ]]; then
    Finish 1 "KILLED"
  fi

  getPkgVarsFromIssuelog || return
  CreateIssueDir
  pkglog_stripped=$issuedir/$(basename $pkglog)
  stripEscapeSequences < $pkglog > $pkglog_stripped

  emerge -qpvO $pkgname &> $issuedir/emerge-qpvO

  cp $logfile $issuedir

  setWorkDir
  CollectIssueFiles

  echo "internal failure: no title guessed from tinderbox logs" > $issuedir/title
  ClassifyIssue
  SearchForBlocker
  SetAssigneeAndCc

  CompileIssueMail  # do it before we might return so that the issue could be still sent manually at any time later

  # https://bugs.gentoo.org/596664
  #
  grep -q -e "configure: error: XML::Parser perl module is required for intltool" $pkglog_stripped
  if [[ $? -eq 0 ]]; then
    try_again=1
    add2backlog "$task"
    add2backlog "%emerge -1 dev-perl/XML-Parser"
    return
  fi

  # https://bugs.gentoo.org/687226
  #
  grep -q -e "MiscXS.c: loadable library and perl binaries are mismatched" $pkglog_stripped
  if [[ $? -eq 0 ]]; then
    try_again=1
    add2backlog "$task"
    add2backlog "%emerge -1 sys-apps/texinfo"
    return
  fi

  grep -q \
          -e "configure: error: perl module Locale::gettext required" \
          -e "Can't locate Locale/Messages.pm in @INC"                \
          $pkglog_stripped
  if [[ $? -eq 0 ]]; then
    if [[ $try_again -eq 0 ]]; then
      try_again=1
      add2backlog "$task"
    fi
    add2backlog "%perl-cleaner --all"
    return
  fi

  if [[ $try_again -eq 1 ]]; then
    add2backlog "$task"
  else
    echo "=$pkg" >> /etc/portage/package.mask/self
  fi

  grep -q -f /mnt/tb/data/IGNORE_ISSUES $issuedir/title
  if [[ $? -ne 0 ]]; then
    SendoutIssueMail
  fi
}


# helper of PostEmerge()
#
function BuildKernel()  {
  echo "$FUNCNAME" >> $logfile
  (
    set -e
    cd /usr/src/linux
    make distclean
    make defconfig
    make -j1
    make modules_install
    make install
  ) &>> $logfile
  return $?
}


# helper of PostEmerge()
# switch to latest GCC
#
function SwitchGCC() {
  latest=$(gcc-config --list-profiles --nocolor | cut -f3 -d' ' -s | grep 'x86_64-pc-linux-gnu-.*[0-9]$' | tail -n 1)

  gcc-config --list-profiles --nocolor | grep -q "$latest \*$"
  if [[ $? -eq 1 ]]; then
    current=$(gcc -dumpversion)

    gcc-config --nocolor $latest &>> $logfile
    source /etc/profile

    add2backlog "%emerge @preserved-rebuild"      # must not fail
    add2backlog "%emerge -1 sys-devel/libtool"    # should be rebuild

    # kick off old GCC installation artifacts to force catching related issues/missing links
    add2backlog "%emerge --unmerge sys-devel/gcc:$current"
  fi
}


# helper of RunAndCheck()
# it schedules follow-ups from the last emerge operation
#
function PostEmerge() {
  # don't change these config files after image setup
  #
  rm -f /etc/._cfg????_{hosts,resolv.conf}
  rm -f /etc/ssmtp/._cfg????_ssmtp.conf
  rm -f /etc/portage/._cfg????_make.conf

  # if eg. a new glibc was installed then rebuild the locales
  ls /etc/._cfg????_locale.gen &>/dev/null
  if [[ $? -eq 0 ]]; then
    locale-gen > /dev/null
    rm /etc/._cfg????_locale.gen
  else
    grep -q "IMPORTANT: config file '/etc/locale.gen' needs updating." $logfile_stripped && locale-gen > /dev/null
  fi

  # merge the remaining config files automatically and update the runtime environment
  #
  etc-update --automode -5 1>/dev/null
  env-update &>/dev/null

  source /etc/profile || Finish 2 "can't source /etc/profile"

  # the very last step after an emerge
  #
  grep -q "Use emerge @preserved-rebuild to rebuild packages using these libraries" $logfile_stripped
  if [[ $? -eq 0 ]]; then
    if [[ ! $task =~ "@preserved-rebuild" || $try_again -eq 0 ]]; then
      add2backlog "@preserved-rebuild"
    fi
  fi

  grep -q -e "Please, run 'haskell-updater'" -e "ghc-pkg check: 'checking for other broken packages:'" $logfile_stripped && add2backlog "%haskell-updater"

  grep -q ">>> Installing .* sys-kernel/gentoo-sources" $logfile_stripped
  if [[ $? -eq 0 ]]; then
    current=$(eselect kernel show 2>/dev/null | grep "gentoo" | cut -f4 -d'/' -s)
    # compile the Gentoo kernel (but only the very first one, ignore any updates)
    if [[ -z "$current" ]]; then
      latest=$(eselect kernel list | grep "gentoo" | tail -n 1 | awk ' { print $2 } ')
      eselect kernel set $latest
    fi

    if [[ ! -f /usr/src/linux/.config ]]; then
      add2backlog "%BuildKernel"
    fi
  fi

  grep -q ">>> Installing .* dev-lang/perl-[1-9]" $logfile_stripped && add2backlog "%perl-cleaner --all"
  grep -q ">>> Installing .* sys-devel/gcc-[1-9]" $logfile_stripped && add2backlog "%SwitchGCC"

  # update the image once a day if nothing 1st prio is scheduled
  #
  if [[ ! -s $backlog1st ]]; then
    local last=""
    if [[ -f /var/tmp/tb/@world.history && -f /var/tmp/tb/@system.history ]]; then
      if [[ /var/tmp/tb/@world.history -nt /var/tmp/tb/@system.history ]]; then
        last=/var/tmp/tb/@world.history
      else
        last=/var/tmp/tb/@system.history
      fi
    elif [[ -f /var/tmp/tb/@world.history ]]; then
      last=/var/tmp/tb/@world.history
    elif [[ -f /var/tmp/tb/@system.history ]]; then
      last=/var/tmp/tb/@system.history
    fi

    if [[ -n $last && $(( $(date +%s) - $(stat -c%Y $last) )) -gt 86400 ]]; then
      add2backlog "@world"
      add2backlog "@system"
      add2backlog "%/usr/bin/pfl || true"    # gather data of installed packages before being updated/lost
    fi
  fi

  grep -q ">>> Installing .* dev-lang/ruby-[1-9]" $logfile_stripped
  if [[ $? -eq 0 ]]; then
    current=$(eselect ruby show | head -n 2 | tail -n 1 | xargs)
    latest=$(eselect ruby list | tail -n 1 | awk ' { print $2 } ')

    if [[ "$current" != "$latest" ]]; then
      add2backlog "%eselect ruby set $latest"
    fi
  fi

  grep -q ">>> Installing .* dev-lang/python-[1-9]" $logfile_stripped
  if [[ $? -eq 0 ]]; then
    add2backlog "%eselect python cleanup"
    add2backlog "%eselect python update --if-unset"
  fi
}


# helper of RunAndCheck()
#
function CheckQA() {
  pushd /var/tmp/tb 1>/dev/null

  # prefer "grep -f <file>" over "grep -e <pattern>"
  split --lines=1 --suffix-length=2 /mnt/tb/data/CATCH_QA

  find /var/log/portage/elog -name '*.log' |\
  while read elogfile
  do
    pkg=$(cut -f1-2 -d':' -s <<< ${elogfile##*/} | tr ':' '/')
    pkgname=$(pn2p "$pkg")
    pkglog=$(ls -1t /var/log/portage/$(echo "$pkg" | tr '/' ':'):????????-??????.log 2>/dev/null | head -n 1)

    # process each QA issue separately (there might be more than 1 in the same elog file)
    #
    for x in x??
    do
      grep -a -f $x $elogfile > title
      if [[ -s title ]]; then
        CreateIssueDir
        pkglog_stripped=$issuedir/$(basename $pkglog)
        stripEscapeSequences < $pkglog > $pkglog_stripped

        mv title $issuedir/title
        grep -a -f $issuedir/title -B 1 -A 5 $elogfile > $issuedir/issue
        cp $issuedir/issue $issuedir/comment0
        cp $issuedir/issue $issuedir/body

        # if QA elog contains more than 7 lines (1 before, 5 after) then attach it too
        if [[ $( wc -l < $elogfile ) -gt 7 ]]; then
          cp $elogfile $issuedir/files/elog-${elogfile##*/}
        fi

        AddWhoamiToComment0
        SearchForBlocker
        repo=$(portageq metadata / ebuild $pkg repository)
        SetAssigneeAndCc
        AddVersionAssigneeAndCC
        SearchForAnAlreadyFiledBug
        AddBgoCommandLine
        collectPortageDir
        sed -i -e "s,^,$pkg : ," $issuedir/title
        TrimTitle
        AttachFilesToBody $issuedir/files/elog*
        CompressIssueFiles
        echo "QAglobalscope" >> $issuedir/keywords

        chmod 777     $issuedir/
        chmod -R a+rw $issuedir/
        if [[ -z "$similar_bug_no" ]]; then
          SendoutIssueMail
        fi
      fi
    done

    mv $elogfile $elogfile.checked
  done

  rm -f x?? title

  popd 1>/dev/null
}


# helper of WorkOnTask()
# run ($1) and act on result
#
function RunAndCheck() {
  (eval $@) &>> $logfile
  local rc=$?

  logfile_stripped=/var/tmp/tb/logs/task.$(date +%Y%m%d-%H%M%S).log
  stripEscapeSequences < $logfile > $logfile_stripped

  PostEmerge

  blocker_bug_no=""
  similar_bug_no=""

  if [[ ! $keyword = "stable" ]]; then
    CheckQA
  fi

  if [[ $rc -eq 0 ]]; then
    return $rc
  fi

  grep -q -e 'emerge: there are no ebuilds built with USE flags to satisfy' \
          -e 'emerge: there are no ebuilds to satisfy' \
          -e 'The following REQUIRED_USE flag constraints are unsatisfied:' \
          -e '!!! One of the following masked packages is required to complete your request:' \
          -e '!! All ebuilds that could satisfy ".*" have been masked.' \
          -e '* Error: The above package list contains packages which cannot be' \
          -e '* Error: circular dependencies:' \
          -e 'It may be possible to solve this' \
          -e '* Invalid resume list:' \
          -e 'Dependencies could not be completely resolved due to' \
          -e "Couldn't find .* to unmerge." \
          -e 'emerge: There are no sets to satisfy' \
          -e '!!! Multiple package instances within a single package slot have been pulled' \
          $logfile_stripped
  if [[ $? -eq 0 ]]; then
    return $rc
  fi

  if [[ $rc -lt 128 ]]; then
    GotAnIssue
  else
    let signal="$rc - 128"
    if [[ $signal -eq 9 ]]; then
      Finish 0 "catched signal $signal - exiting"
    else
      Mail "INFO: emerge got signal $signal" $logfile_stripped
    fi
  fi

  return $rc
}


# this is the heart of the tinderbox
#
function WorkOnTask() {
  try_again=0           # 1 usually means to retry task, but eg. with "test-fail-continue"
  pkg=""                # eg. app-portage/eix-0.33.11
  pkglog=""             # logfile
  pkglog_stripped=""    # stripped escape sequences and more from it
  pkgname=""            # eg. app-portage/eix

  local rc

  # @set
  #
  if [[ $task =~ ^@ ]]; then
    opts="--deep --backtrack=30"
    if [[ ! $task = "@preserved-rebuild" ]]; then
      opts="$opts --update"
      if [[ $task = "@system" || $task = "@world" ]]; then
        opts="$opts --newuse --changed-use --exclude kernel/gentoo-sources"
      fi
    fi
    RunAndCheck "emerge $task $opts"
    rc=$?

    if [[ $rc -ne 0 ]]; then
      echo "$(date) NOT ok $pkg" >> /var/tmp/tb/$task.history
      if [[ $try_again -eq 0 ]]; then
        if [[ -n "$pkg" ]]; then
          add2backlog "%emerge --resume --skip-first"
        fi
      fi
    else
      echo "$(date) ok" >> /var/tmp/tb/$task.history
      if [[ $task = "@world" ]]; then
        add2backlog "%emerge --depclean || true"
      fi
    fi

    cp $logfile /var/tmp/tb/$task.last.log

  # %<command>
  #
  elif [[ $task =~ ^% ]]; then
    cmd="$(echo "$task" | cut -c2-)"
    RunAndCheck "$cmd"
    rc=$?

    if [[ $rc -ne 0 ]]; then
      if [[ $try_again -eq 0 ]]; then
        if [[ $task =~ " --resume" ]]; then
          if [[ -n "$pkg" ]]; then
            add2backlog "%emerge --resume --skip-first"
          else
            grep -q ' Invalid resume list:' $logfile_stripped
            if [[ $? -eq 0 ]]; then
              add2backlog "$(tac $taskfile.history | grep -m 1 '^%')"
            fi
          fi
        elif [[ ! $task =~ " --unmerge " && ! $task =~ "emerge -C " && ! $task =~ " --depclean" && ! $task =~ " --fetchonly" && ! $task =~ "BuildKernel" ]]; then
          Finish 3 "command: '$cmd'"
        fi
      fi
    fi

  # pinned package version
  #
  elif [[ $task =~ ^= ]]; then
    RunAndCheck "emerge $task"

  # anything else
  #
  else
    RunAndCheck "emerge --update $task"
  fi
}


# heuristic:
#
function DetectALoop() {
  x=7
  if [[ $name =~ "test" ]]; then
    x=18
  fi
  let "y = x * 2"

  for t in "@preserved-rebuild" "%perl-cleaner"
  do
    if [[ ! $task =~ $t ]]; then
      continue
    fi

    n=$(tail -n $y $taskfile.history | grep -c "$t")
    if [[ $n -ge $x ]]; then
      for i in $(seq 1 $y)
      do
        echo "#" >> $taskfile.history
      done
      Finish 1 "${n}x $t among last $y tasks"
    fi
  done
}


# sync all repositories with the one(s) at the host system
# Hint: the file "timestamp.git" is created by sync_repo.sh
#
function updateAllRepos() {
  for image_repo in $(ls -d /var/db/repos/* 2>/dev/null | grep -v -e "/local" -e "/tinderbox")
  do
    host_repo=/mnt/repos/$(basename $image_repo)
    if [[ ! -d $host_repo ]]; then
      continue
    fi

    if [[ ! -f $image_repo/timestamp.git || $(cat $image_repo/timestamp.git) != $(cat $host_repo/timestamp.git) ]]; then
      # very unlikely but if a git pull at the host is running then wait till it finished
      while [[ -f $host_repo/.git/index.lock ]]
      do
        sleep 1
      done
      rsync --archive --cvs-exclude --delete $host_repo /var/db/repos/
    fi
  done
}


#############################################################################
#
#       main
#
export LANG=C.utf8

mailto="tinderbox@zwiebeltoralf.de"
taskfile=/var/tmp/tb/task           # holds the current task
logfile=$taskfile.log               # holds output of the current task
backlog1st=/var/tmp/tb/backlog.1st  # the high prio backlog

export GCC_COLORS=""
export OCAML_COLOR="never"
export CARGO_TERM_COLOR="never"
export PYTEST_ADDOPTS="--color=no"
export PY_FORCE_COLOR="0"

# https://bugs.gentoo.org/683118
#
export TERM=linux
export TERMINFO=/etc/terminfo

name=$(cat /var/tmp/tb/name)
grep -q '^ACCEPT_KEYWORDS=.*~amd64' /etc/portage/make.conf && keyword="unstable" || keyword="stable"

# retry $task if task file is non-empty (eg. after a terminated emerge)
if [[ -s $taskfile ]]; then
  add2backlog "$(cat $taskfile)"
  truncate -s 0 $taskfile
fi

# if we were hard stopped then clean up
add2backlog "%emaint --fix merges"

while [[ : ]]
do
  date > $logfile

  # pick up after ourself b/c "auto-clean" in FEATURES is deactivated to collect issue files
  #
  rm -rf /var/tmp/portage/*

  if [[ -f /var/tmp/tb/STOP ]]; then
    echo "#stopping" > $taskfile
    Finish 0 "catched STOP file" /var/tmp/tb/STOP
  fi

  echo "#rsync repos" > $taskfile
  updateAllRepos

  echo "#get task" > $taskfile
  getNextTask
  WorkOnTask
  truncate -s 0 $taskfile

  DetectALoop
done
